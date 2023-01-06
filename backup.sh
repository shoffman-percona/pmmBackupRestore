#!/bin/bash

####
# Still NEED
# Run backups in parallel for speed? have to monitor for all 3 being done before moving on
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

if [[ $UID -ne 0 ]] ; then
  sudo mkdir -p $backup_root
  sudo chown `id -un`.`id -un` $backup_root
else 
  mkdir -p $backup_root
fi
	

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
-r, --restore YYYYMMDD_HHMMSS
       Restore backup with date/time code of YYYYMMDD_HHMMSS to a PMM server of the same version (.tar.gz file must be in $backup_root directory)
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
#    -i | --interactive) interactive=1 ;;
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

#######################################
# Runs command as root.
#######################################
run_root() {
  sh='sh -c'
  if [ "$(id -un)" != 'root' ]; then
    if check_command sudo; then
      sh='sudo -E sh -c'
    elif check_command su; then
      sh='su -c'
    else
      die "${RED}ERROR: root rights needed to run "$*" command ${NOFORMAT}"
    fi
  fi
  ${sh} "$@" &>>$logfile
}  

######################################
# Verify and satisfy prerequisites
######################################
check_prereqs() {

	msg "Checking for/installing prerequisite software...an internet connection is requried or you must install missing softare manually"
	if ! check_command wget; then
		if ! yum install -y wget; then 
			die "Could not download needed component...check internet?"
		fi
	fi

	#set version 
	if [ "$restore" == 0 ] ; then
		#yum info -q --disablerepo="*source*" pmm-managed | grep -Em1 ^Version | sed 's/.*: //' > $backup_dir/pmm_version.txt
		mkdir -p "$backup_dir"
		pmm-managed --version 2> >(grep -Em1 ^Version) | sed 's/.*: //' > "$backup_dir"/pmm_version.txt

		if ! check_command /tmp/vmbackup-prod; then
			cd /tmp
			vm_version=$(victoriametrics --version | cut -d '-' -f7)
			if ! wget https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/"$vm_version"/vmutils-amd64-"$vm_version".tar.gz >> $logfile; then
				die "Could not download needed component...check internet?"
			fi
			tar zxf vmutils-amd64-"$vm_version".tar.gz
		fi

	elif [ "$restore" != 0 ] ; then 
		msg "Extracting Backup Archive"
		restore_from_dir="$backup_root/pmm_backup_$restore"
		restore_from_file="$backup_root/pmm_backup_$restore.tar.gz"
		mkdir -p "$restore_from_dir"
		tar zxf "$restore_from_file" -C "$restore_from_dir"
		backup_pmm_version=$(cat "$restore_from_dir"/pmm_version.txt)
		restore_to_pmm_version=$(pmm-managed --version 2> >(grep -Em1 ^Version) | sed 's/.*: //')
		if [ "$backup_pmm_version" != "$restore_to_pmm_version" ] ; then 
			die "Cannot restore backup from PMM version $backup_pmm_version to PMM version $restore_to_pmm_version, install $backup_pmm_version on this host and retry." 
		fi

		if ! check_command /tmp/vmrestore-prod; then
			cd /tmp
			vm_version=$(victoriametrics --version | cut -d '-' -f7)
			if ! wget https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/"$vm_version"/vmutils-amd64-"$vm_version".tar.gz >> $logfile; then
				die "Could not download needed component...check internet?"
			fi
			tar zxf vmutils-amd64-"$vm_version".tar.gz
		fi
	fi


### nice to haves ###
	#will the backup fit on the filesystem (need >2x the size of the /srv directory)



}

######################################
# Perform Backup of PMM
######################################
perform_backup() {


	#setup env
	msg "Creating backup directory structure"
	mkdir -p "$backup_root"/"$backup_version"/{postgres,vm,clickhouse,folders}


	#pg backup
	msg "Starting PostgreSQL backup"
	run_root "pg_dump -c -U pmm-managed > "$backup_dir"/postgres/backup.sql"
	msg "Completed PostgreSQL backup"

	#vm backup
	msg "Starting VictoriaMetrics backup"
	run_root "/tmp/vmbackup-prod --storageDataPath=/srv/victoriametrics/data -snapshot.createURL=http://localhost:9090/prometheus/snapshot/create -dst=fs://"$backup_dir"/vm/ -loggerOutput=stdout"
	msg "Completed VictoriaMetrics backup"

	#clickhouse Backup

	msg "Starting Clickhouse backup"
	mapfile -t ch_array < <(/bin/clickhouse-client --host=127.0.0.1 --query "select name from system.tables where database = 'pmm'")
	for table in "${ch_array[@]}"
	do
		if [ "$table" == "schema_migrations" ] ; then
			msg "  Backing up $table table"
			/bin/clickhouse-client --host=127.0.0.1 --database "pmm" --query="SHOW CREATE TABLE $table" --format="TabSeparatedRaw" > "$backup_dir"/clickhouse/"$table".sql
			/bin/clickhouse-client --host=127.0.0.1 --database "pmm" --query="SELECT * from $table" --format CSV > "$backup_dir"/clickhouse/"$table".data
		else
			msg "  Backing up $table table"
			/bin/clickhouse-client --host=127.0.0.1 --database "pmm" --query="SHOW CREATE TABLE $table" --format="TabSeparatedRaw" > "$backup_dir"/clickhouse/"$table".sql
			/bin/clickhouse-client --host=127.0.0.1 --query "alter table pmm.$table freeze"
		fi
	done
		run_root "mv /srv/clickhouse/shadow "$backup_dir"/clickhouse/"$backup_version""
	msg "Completed Clickhouse backup"

	#support files backup
	msg "Backing up configuration and supporting files"

	run_root "cp -af /srv/alerting "$backup_dir"/folders/"
	run_root "cp -af /srv/alertmanager "$backup_dir"/folders/"
	run_root "cp -af /srv/grafana "$backup_dir"/folders/"
	run_root "cp -af /srv/nginx "$backup_dir"/folders/"
	run_root "cp -af /srv/prometheus "$backup_dir"/folders/"
	run_root "cp -af /srv/pmm-distribution "$backup_dir"/folders/"

	msg "Completed configuration and supporting files backup"

	msg "Compressing backup artifact"
	run_root "tar -czf "$backup_root"/"$backup_version".tar.gz -C "$backup_dir" ."
	msg "Cleaning up"
	run_root "rm -rf "$backup_dir""
	msg "\nBackup Complete"
}


######################################
# Perform Restore of PMM
######################################
perform_restore() {

	#stop pmm-managed locally to restore data
	msg "Stopping pmm-managed to begin restore"
	run_root "supervisorctl stop pmm-managed nginx"
	msg "pmm-managed stopped, restore starting"
	
	#pg restore
	msg "Starting PostgreSQL restore"
	psql -U pmm-managed -f "$restore_from_dir"/postgres/backup.sql &>>$logfile 
	msg "Completed PostgreSQL restore"

	#vm restore
	msg "Starting VictoriaMetrics restore"
	run_root "supervisorctl stop victoriametrics"
	run_root "/tmp/vmrestore-prod -src=fs:///"$restore_from_dir"/vm/ -storageDataPath=/srv/victoriametrics/data"
	run_root "chown -R pmm.pmm /srv/victoriametrics/data"
	run_root "supervisorctl start victoriametrics"
	msg "Completed VictiriaMetrics restore"
	

	#clickhouse restore
	msg "Starting Clickhouse restore"
	#stop qan api 
	run_root "supervisorctl stop qan-api2"
	#will need to loop through $tables
	mapfile -t ch_array < <(ls "$restore_from_dir"/clickhouse | grep .sql | sed "s/\.sql//")
	for table in "${ch_array[@]}"; do
		if [ "$table" == "schema_migrations" ] ; then
			# schema_migrations only needs SQL replay, other tables need data copies and reattaching files
			msg "  Restoring $table table"
			/bin/clickhouse-client --host=127.0.0.1 --database "pmm" --query="drop table if exists $table"
			cat "$restore_from_dir"/clickhouse/"$table".sql | /bin/clickhouse-client --host=127.0.0.1 --database "pmm"
			# this can be improved as all the data to form this statement is in $table.sql and will 
			# be a bit more future-proofed if table structure changes
			cat "$restore_from_dir"/clickhouse/"$table".data | /bin/clickhouse-client --host=127.0.0.1 --database "pmm" --query "INSERT INTO pmm.$table SELECT version, dirty, sequence FROM input('version UInt32, dirty UInt8, sequence UInt64') FORMAT CSV"
			#check that num rows in == num rows inserted
			rows_in=$(/bin/wc -l "$restore_from_dir"/clickhouse/"$table".data | cut -d " " -f1)
			rows_inserted=$(clickhouse-client --host=127.0.0.1 --database "pmm" --query="select count(*) from $table")
			if [ "$rows_in" == "$rows_inserted" ] ; then 
				msg "  Successfully restored $table"
			else
				msg "  There was a problem restoring $table, $rows_in rows backed up but $rows_inserted restored"
			fi
		else
			msg "  Restoring $table table"
			/bin/clickhouse-client --host=127.0.0.1 --database "pmm" --query="drop table if exists $table"
			cat "$restore_from_dir"/clickhouse/"$table".sql | /bin/clickhouse-client --host=127.0.0.1 --database "pmm"
			[ ! -d "/srv/clickhouse/data/pmm/$table/detached" ] && run_root "mkdir -p /srv/clickhouse/data/pmm/"$table"/detached/"
			msg "  Copying files"
			folder=$(cat "$restore_from_dir"/clickhouse/pmm_backup_"$restore"/increment.txt)
			run_root "cp -rlf "$restore_from_dir"/clickhouse/pmm_backup_"$restore"/"$folder"/data/pmm/"$table"/* /srv/clickhouse/data/pmm/"$table"/detached/"
			msg "  Gathering partitions"
			[[ $UID -ne 0 ]] && run_root "chmod -R o+rx /srv/clickhouse"; 
			mapfile -t partitions < <(ls /srv/clickhouse/data/pmm/"$table"/detached/ | cut -d "_" -f1 | uniq)
			[[ $UID -ne 0 ]] &&run_root "chmod -R o-rx /srv/clickhouse";
			for partition in "${partitions[@]}"; do 
				msg "    Loading partition $partition"
				/bin/clickhouse-client --host=127.0.0.1 --database "pmm" --query="alter table $table attach partition $partition"
			done
		fi
	done


	msg "Completed Clickhouse restore"

	#support files restore
	msg "Starting configuration and file restore"
	#$/srv/alerting (root,root)
	run_root "cp -af "$restore_from_dir"/folders/alerting/ /srv/alerting"
	run_root "chown -R root.root /srv/alerting"
	#/srv/alertmanager (pmm,pmm)
	run_root "cp -af "$restore_from_dir"/folders/alertmanager/ /srv/alertmanager"
	run_root "chown -R pmm.pmm /srv/alertmanager"
	#/srv/grafana (grafana,grafana)
	run_root "cp -af "$restore_from_dir"/folders/grafana/ /srv/grafana"
	run_root "chown -R grafana.grafana /srv/grafana"
	#/srv/nginx (root,root)
	run_root "cp -af "$restore_from_dir"/folders/nginx/ /srv/nginx"
	run_root "chown -R root.root /srv/nginx"
	#/srv/prometheus (pmm,pmm)
	run_root "cp -af "$restore_from_dir"/folders/prometheus/ /srv/prometheus"
	run_root "chown -R pmm.pmm /srv/prometheus"
	#/srv/pmm-distribution (root,root) (optional)
	run_root "cp -af "$restore_from_dir"/folders/pmm-distribution /srv/"
	run_root "chown -R root.root /srv/pmm-distribution"

	#last step
	msg "Restarting servies"
	run_root "supervisorctl restart grafana nginx pmm-managed qan-api2"
	msg "Completed configuration and file restore"

	# cleanup
	run_root "rm -rf "$restore_from_dir""
}

main() {
	setup_colors
	if [ "$restore" != 0 ]; then 
		#do restore stuff here
		msg "Restoring backup pmm_backup_$restore.tar.gz"
		check_prereqs
		perform_restore
	else
		check_prereqs
		perform_backup
	fi
	
}

parse_params "$@"
main
die "Thank you for using the PMM Backup Tool!" 0 


