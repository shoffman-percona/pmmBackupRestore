#!/bin/bash

####
# Still NEED
# get version of PMM being backed up (and restore needs to verify it's being restored to same version or error out
# Run backups in parallel for speed? have to monitor for all 3 being done before moving on
# Redirect all output to a log stored outside of backup artifact
# Do we need to backup pmm logs?  I think no but asking anyway
# Args and help (assuming running script by itself will backup with all defaults but do we allow overrides? i.e. storage location of backup?
#
####

######################################
# Set Defaults
######################################
backup_version="pmm_backup_$(date +%Y%m%d_%H%M%S)"
backup_root="/srv/backups"
backup_dir=$backup_root/$backup_version
restore=0
logfile="$backup_root/pmmBackup.log"
mkdir -p $backup_root

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT


#######################################
# Show script usage info.
#######################################
usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-i] [-t] [-n] [-p]
This tool is used to take online backups and can be used to restore a backup as well.
Available options:
-h, --help          Print this help and exit
-v, --verbose       Print script debug info
-i, --interactive   Run script in interactive mode
-r, --restore="YYYYMMDD_HHMMSS"
       Restore backup with date/time code of YYYYMMDD_HHMMSS to a PMM server of the same version
EOF
  exit
}

#######################################
# Accept and parse script's params.
#######################################
parse_params() {
  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    -i | --interactive) interactive=1 ;;
    -r | --restore)
      restore="${2-}"
      shift
      ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  return 0
}

#######################################
# Clean up setup if interrupt.
#######################################
cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
}

#######################################
# Defines colours for output messages.
#######################################
setup_colors() {
  if [[ -t 2 ]] && [[ -z "${NO_COLOR-}" ]] && [[ "${TERM-}" != "dumb" ]]; then
    NOFORMAT='\033[0m' RED='\033[0;31m' GREEN='\033[0;32m' ORANGE='\033[0;33m'
    BLUE='\033[0;34m' PURPLE='\033[0;35m' CYAN='\033[0;36m' YELLOW='\033[1;33m'
  else
    NOFORMAT='' RED='' GREEN='' ORANGE='' BLUE='' PURPLE='' CYAN='' YELLOW=''
  fi
}

#######################################
# Prints message to stderr with new line at the end.
#######################################
msg() {
  echo >&2 -e "${1-}"
}

#######################################
# Prints message and exit with code.
# Arguments:
#   message string;
#   exit code.
# Outputs:
#   writes message to stderr.
#######################################
die() {
  local msg=$1
  local code=${2-1} # default exit status 1
  msg "$msg"
  exit "$code"
}

#######################################
# Check if Command exists
#######################################

check_command() {
  command -v "$@" 1>/dev/null
}

######################################
# Verify and satisfy prerequisites
######################################
check_prereqs() {
        msg "Verifying and possibly installing prerequisite software...an internet connection is requried or you must install missing softare manually"
        if ! check_command wget; then
                yum install -y wget
        fi

        if ! check_command /tmp/vmbackup-prod; then
                cd /tmp
                vm_version=`victoriametrics --version | cut -d '-' -f7`
                wget https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/$vm_version/vmutils-amd64-$vm_version.tar.gz >> $logfile 
                tar zxvf vmutils-amd64-$vm_version.tar.gz >> $logfile
        fi
}

######################################
# Perform Backup of PMM
######################################
perform_backup() {

### --> GET PMM VERSION 

        #setup env
        msg "Creating backup directory structure"
        mkdir -p $backup_root/$backup_version/{postgres,vm,clickhouse,folders}


        #pg backup
        msg "Starting PostgreSQL backup"
        pg_dump -c -U pmm-managed > $backup_dir/postgres/backup.sql
        msg "Completed PostgreSQL backup"

        #vm backup
        msg "Starting VictoriaMetrics backup"
        /tmp/vmbackup-prod --storageDataPath=/srv/victoriametrics/data -snapshot.createURL=http://localhost:9090/prometheus/snapshot/create -dst=fs://$backup_dir/vm/ -loggerOutput=stdout >> $logfile
        msg "Completed VictoriaMetrics backup"

        #clickhouse Backup

        msg "Starting Clickhouse backup"
        mapfile -t ch_array < <(/bin/clickhouse-client --host=127.0.0.1 --query "select name from system.tables where database = 'pmm'")
        for table in "${ch_array[@]}"
        do
                if [ "$table" == "schema_migrations" ] ; then
                        msg "  Backing up $table table"
                        /bin/clickhouse-client --host=127.0.0.1 --database "pmm" --query="SHOW CREATE TABLE $table" --format="TabSeparatedRaw" > $backup_dir/clickhouse/$table.sql
                        /bin/clickhouse-client --host=127.0.0.1 --database "pmm" --query="SELECT * from $table" --format CSV > $backup_dir/clickhouse/$table.data
                else
                        msg "  Backing up $table table"
                        /bin/clickhouse-client --host=127.0.0.1 --database "pmm" --query="SHOW CREATE TABLE $table" --format="TabSeparatedRaw" > $backup_dir/clickhouse/$table.sql
                        /bin/clickhouse-client --host=127.0.0.1 --query "alter table pmm.$table freeze"
                fi
        done
                mv /srv/clickhouse/shadow $backup_dir/clickhouse/$backup_version
        msg "Completed Clickhouse backup"

        #support files backup
        msg "Backing up configuration and supporting files"

        cp -af /srv/alerting $backup_dir/folders/
        cp -af /srv/alertmanager $backup_dir/folders/
        cp -af /srv/grafana $backup_dir/folders/
        cp -af /srv/nginx $backup_dir/folders/
        cp -af /srv/prometheus $backup_dir/folders/
        cp -af /srv/pmm-distribution $backup_dir/folders/

        msg "Completed configuration and supporting files backup"

        msg "Compressing backup artifact"
        tar -czf $backup_root/$backup_version.tar.gz $backup_dir >> $logfile
        msg "Cleaning up"
        rm -rf $backup_dir
        msg "\nBackup Complete"
}




#pg restore
#psql -U pmm-managed -f /tmp/backup.sql


#vm restore
#./vmrestore-prod -src=fs:///srv/backup/vm/ -storageDataPath=/srv/victoriametrics/data

#clickhouse restore
#will need to loop through #tablenames
#cat $tablename.sql | clickhouse-client --host=127.0.0.1 --database pmm
#mv $SOURCE_BACKUP_LOCATION/data/pmm/$tablename/* /srv/clickhouse/data/pmm/$tablename/detached/
#clickhouse-client --database pmm --query "ALTER TABLE $tablename ATTACH PARTITION 202111"

#support files restore
#perms too
#$/srv/alerting (root,root)
#/srv/alertmanager (pmm,pmm)
#/srv/grafana (grafana,grafana)
#/srv/ia (root,root)
#/srv/nginx (root,root)
#/srv/prometheus (pmm,pmm)
#/srv/pmm-distribution (root,root) (optional)

#last step
#supervisorctl restart pmm-managed postgresql clickhouse victoriametrics grafana nginx alertmanager qan-api2 vmalert

main() {
        setup_colors
        check_prereqs
        if [ $restore != 0 ]; then 
                #do restore stuff here
                msg 'restore coming soon'
        else
                perform_backup
        fi
        
}

parse_params "$@"
main
die "PMM Backup Tool" 0 
