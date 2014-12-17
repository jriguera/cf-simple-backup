#!/usr/bin/env bash
#
# cf simple backup
# (c) 2014 Jose Riguera <jose.riguera@springer.com>
# Licensed under GPLv3

# First we need to setup the Global variables, only if their default values
# are wrong for this script
DEBUG=0
EXEC_USER=$USER                # normally must be an user or $USER to avoid 
                               # changuing the user automaticaly with sudo.
# Other variables
PROGRAM=${PROGRAM:-$(basename $0)}
PROGRAM_DIR=$(cd $(dirname "$0"); pwd)
NAME=$PROGRAM
DESC="cf simple backup"
PROCESS_TIME_LIMIT=600

# Load the library and load the configuration file if it exists
REALPATH=$(readlink "$PROGRAM")
if [ ! -z "$REALPATH" ]; then
    REALPATH=$(dirname "$REALPATH")
    _COMMON="$REALPATH/_libs/_common.sh"
else
    _COMMON="$PROGRAM_DIR/_libs/_common.sh"
fi
if ! [ -f "$_COMMON" ]; then
    msg="$(date "+%Y-%m-%d %T"): Error $_COMMON not found!"
    logger -s -p local0.err -t ${0} "$msg"
    exit 1
fi
. $_COMMON

# Program variables
RSYNC="sudo rsync -arzhv -x -AX --delete"
MOUNT_NFS="sudo mount -t nfs -o ro,soft,nolock"
UMOUNT="sudo umount -f"
MOUNT="sudo mount"
BOSH="bosh"
DBDUMP="pg_dump --clean --create"
TAR="tar -zcvf"
PING="ping -c 3"

# Functions and procedures
set +e

# help
usage() {
    cat <<EOF
Usage:

    $PROGRAM  [-h | --help ] [-d | --debug] [-c | --config <configuration-file>] <action>

$DESC

Arguments:

   -h, --help         Show this message
   -d, --debug        Debug mode
   -c, --config       Configuration file

Action:

   backup             Perform backup

EOF
}


bosh_info() {
    local user="$1"
    local host="$2"
    local pass="$3"
    local config="$4"
    local dep="$5"
    local infor="$6"
    local manifest="$7"

    echon_log "Targeting and login microbosh ${host} ... "
    $BOSH -c "${config}" -u zzz -p zzz target "${host}" >> $PROGRAM_LOG 2>&1 
    $BOSH -c "${config}" login ${user} ${pass} >> $PROGRAM_LOG 2>&1
    rvalue=$?
    if [ $rvalue  != 0 ]; then
        echo "failed!"
    	error_log "Error, bosh login failed!"
        return $rvalue
    fi
    echo "done!"
    echon_log "Getting bosh status ... "
    $BOSH -c "${config}" status >> $PROGRAM_LOG 2>&1
    rvalue=$?
    if [ $rvalue  != 0 ]; then
        echo "failed!"
    	error_log "Error, bosh status failed!"
        return $rvalue
    fi
    echo "ok"
    debug_log "Getting bosh vms: "
    $BOSH -c "${config}" vms ${dep} | awk '/ postgres_| nfs_/{ print $2"|"$8 }' > "${infor}" 2>&1
    rvalue=$?
    if [ $rvalue  != 0 ]; then
        rm -f "${infor}"
    	error_log "Error, bosh vms failed!"
        return $rvalue
    fi
    cat "${infor}" >> $PROGRAM_LOG
    echon_log "Getting bosh manifest for ${dep} ... "
    $BOSH -c "${config}" download manifest "${dep}" "${manifest}" >> $PROGRAM_LOG  2>&1
    rvalue=$?
    if [ $rvalue  != 0 ]; then
        echo "failed!"
    	error_log "Error, bosh download manifest failed!"
        return $rvalue
    fi
    echo "$(basename ${manifest})"
    debug_log "Bosh logout "
    $BOSH -c "${config}" logout >> $PROGRAM_LOG 2>&1
    return $?
}


dbs_dump() {
    local host="$1"
    local dst="$2"
    local dbs="$3"

    local rvalue=0
    local user
    local pass
    local db
    local d
    local dba

    echo_log "Starting DB backup."
    for d in ${dbs}; do
        user=$(echo "$d" | cut -d':' -f 2)
        pass=$(echo "$d" | cut -d':' -f 3)
        db=$(echo "$d" | cut -d':' -f 1)
        dba=$db
    	echon_log "Dumping database ${db} ... "
        db="postgresql://${user}:${pass}@${host}:5524/${db}?connect_timeout=30"
        $DBDUMP -f "${dst}.${dba}" -d ${db} >> $PROGRAM_LOG 2>&1
        rvalue=$?
        if [ $rvalue != 0 ]; then
             echo "error!"
    	     error_log "DB dump failed!"
             return $rvalue
        fi
        echo "done!"
    done
    return $rvalue
}


nfs_files() {
    local host="$1"
    local remote="$2"
    local dst="$3"
    local filelist="$4"

    local rvalue=0
    local target="/tmp/${PROGRAM}_$$_$(date '+%Y%m%d%H%M%S')"
    local logfile="/tmp/${PROGRAM}_$$_$(date '+%Y%m%d%H%M%S').rsync.log"

    echon_log "Mounting remote blobstore ... "
    mkdir -p "${target}" && $MOUNT_NFS ${host}:"${remote}" "${target}" 2>&1 | tee -a $PROGRAM_LOG
    rvalue=${PIPESTATUS[0]}
    if [ $rvalue -eq 0 ]; then
        echo "done!"
    else
        error_log "Mount failed!"
        return $rvalue
    fi
    echon_log "Copying files with rsync ... "
    # $RSYNC --filter="merge ${filelist}" --log-file=${logfile} "${target}/" "${dst}/" >>$PROGRAM_LOG 2>&1
    $RSYNC --include-from="${filelist}" --log-file=${logfile} "${target}/" "${dst}/" >>$PROGRAM_LOG 2>&1
    rvalue=$?
    cat "${logfile}" >> $PROGRAM_LOG
    if [ $rvalue -eq 0 ]; then
        echo "done!"
    else
        echo "error!"
        cat "${logfile}"
    fi
    rm -f "${logfile}"
    echon_log "Umounting remote blobstore ... "
    $UMOUNT "${target}" >>$PROGRAM_LOG 2>&1
    rvalue=$?
    if [ $rvalue  != 0 ]; then
        echo "failed!"
        error_log "Umount failed!"
        return $rvalue
    else
        echo "done"
        rm -rf "${target}"
    fi
    return $rvalue
}


archive() {
    local dst="$1"
    local output="$2"
    local added="$3"

    local logfile="/tmp/${PROGRAM}_$$_$(date '+%Y%m%d%H%M%S').tar.log"

    echon_log "Adding extra files: "
    for f in ${added}; do
        echo -n "${f}"
        cp -v "${f}" "${dst}/" >>$PROGRAM_LOG 2>&1 || echo -n "(failed) " && echo -n " "
    done
    echo
    echon_log "Creating tgz $output ... "
    $TAR ${output} ${dst} 2>&1 | tee -a $PROGRAM_LOG > "${logfile}"
    rvalue=${PIPESTATUS[0]}
    if [ $rvalue -eq 0 ]; then
        echo "done!"
    else
        echo "error!"
        cat "${logfile}"
    fi
    rm -f "${logfile}"
    return $rvalue
}



backup() {
    local user="$1"
    local host="$2"
    local pass="$3"
    local deployment="$4"
    local dbs="$5"
    local cache="$6"
    local filelist="$7"
    local output="$8"
    local addlist="$9"

    local rvalue=0
    local currentdate="$(date '+%Y%m%d%H%M%S')"
    local remote="/var/vcap/store"
    local tmpfile="/tmp/${PROGRAM}_$$_${currentdate}.rsync.list"
    local hostsfile="/tmp/${PROGRAM}_$$_${currentdate}.hosts"
    local manifest="${cache}/cf_manifest_${currentdate}.yml"
    local boshconfig="${cache}/_bosh_config_${currentdate}.cfg"
    local dbdir="${cache}/dbs/"
    local dbdump="${dbdir}/postgres_${currentdate}.dump"
    local rsynccache="${cache}/store/"
    local nfshost
    local dbhost

    debug_log "Deleting old bosh config and manifest files ..."
    rm -f "${cache}/"cf_manifest_*.yml >>$PROGRAM_LOG 2>&1
    rm -f "${cache}/"_bosh_config_*.cfg >>$PROGRAM_LOG 2>&1
    echo $(date '+%Y%m%d%H%M%S') > "${cache}/_date.control"
    bosh_info "${user}" "${host}" "${pass}" "${boshconfig}" "${deployment}" "${hostsfile}" "${manifest}"
    rvalue=$?
    if [ "$rvalue" != "0" ] || [ ! -e "${hostsfile}" ]; then
        rm -f "${hostsfile}"
        return 1
    fi
    echon_log "Locating db and nfs hosts ... "
    dbhost=$(grep -e "^postgres_" "${hostsfile}" | head -n 1 | cut -d'|' -f 2)
    nfshost=$(grep -e "^nfs_" "${hostsfile}" | head -n 1 | cut -d'|' -f 2)
    rm -f "${hostsfile}"
    if [ -z "${dbhost}" ] || [ -z "${nfshost}" ]; then
        echo "failed!"
        error_log "unable to find nfs and db host on cf environment"
        return 1
    fi
    echo "done!"
    echon_log "Pinging ${dbhost} and ${nfshost} ... "
    $PING ${dbhost} >>$PROGRAM_LOG 2>&1 && $PING ${nfshost} >>$PROGRAM_LOG 2>&1
    rvalue=$?
    if [ $rvalue != 0 ]; then
        echo "failed"
        error_log "unable to reach db or nfs hosts!"
        return 1
    fi
    echo "ok"
    echon_log "Checking if ${nfshost}:${remote} is mounted ... "
    $MOUNT | grep -q -e "${nfshost}:${remote}"
    rvalue=$?
    if [ $rvalue == 0 ]; then
        echo "mounted!"
        error_log "aborting backup ... is it already mounted?, is another backup running?"
        return 1
    fi
    echo "ok, not mounted"
    debug_log "Removing old db backups ... "
    rm -rf "${dbdir}" >>$PROGRAM_LOG 2>&1
    debug_log "Creating backup dir ... "
    mkdir -p "${dbdir}" >>$PROGRAM_LOG 2>&1
    debug_log "Preparing list of files ... "
    get_list "${filelist}" | tee -a $PROGRAM_LOG > $tmpfile
    # starting main things
    dbs_dump ${dbhost} "${dbdump}" "${dbs}"
    rvalue=$?
    if [ $rvalue != 0 ]; then
        rm -f "${tmpfile}"
        return $rvalue
    fi
    nfs_files ${nfshost} "${remote}" "${rsynccache}" "${tmpfile}"
    rvalue=$?
    echo $(date '+%Y%m%d%H%M%S') >> "${cache}/_date.control"
    if [ $rvalue == 0 ] && [ ! -z "${output}" ]; then
        archive "${cache}" "${output}" "$(get_list ${addlist})"
        rvalue=$?
    fi
    debug_log "Copying $PROGRAM_LOG ..."
    rm -f "${cache}/"*.log
    cp -v "$PROGRAM_LOG" "${cache}/" >>$PROGRAM_LOG 2>&1
    rm -f "${tmpfile}"
    return $rvalue
}



# Main Program
# Parse the input
OPTIND=1
while getopts "hdc:-:" optchar; do
    case "${optchar}" in
        -)
            # long options
            case "${OPTARG}" in
                help)
                    usage
                    exit 0
                ;;
                debug)
                    DEBUG=1
                ;;
                config)
                  eval PROGRAM_CONF="\$${OPTIND}"
                  OPTIND=$(($OPTIND + 1))
                  [ ! -f "$PROGRAM_CONF" ] && die "Configuration file not found!"
                  . $PROGRAM_CONF && debug_log "($$): CONF=$PROGRAM_CONF"
                ;;
                *)
                    die "Unknown arg: ${OPTARG}"
                ;;
            esac
        ;;
        h)
            usage
            exit 0
        ;;
        d)
            DEBUG=1
        ;;
        c)
            PROGRAM_CONF=$OPTARG
            [ ! -f "$PROGRAM_CONF" ] && die "Configuration file not found!"
            . $PROGRAM_CONF && debug_log "($$): CONF=$PROGRAM_CONF"
        ;;
    esac
done
shift $((OPTIND-1)) # Shift off the options and optional --.
# Parse the rest of the options
RC=1
while [ $# -gt 0 ]; do
    case "$1" in
        backup)
            backup "${BOSH_USER}" "${BOSH_HOST}" "${BOSH_PASS}" "${BOSH_DEPLOYMENT}" "${CF_DBS}" "${CACHE}" "RSYNC_LIST" "${OUTPUT}" "ADD_LIST"
            RC=$?
        ;;
        *)
            usage
            die "Unknown arg: ${1}"
        ;;
    esac
    shift
done

exit $RC

# EOF

