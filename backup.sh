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
backup_dir=${backup_root}/${backup_version}
clickhouse_database="pmm"
restore=0
upgrade=false
logfile="${backup_root}/pmmBackup.log"



set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT


#######################################
# Show script usage info.
#######################################
usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-i] [-s] [-r] [-u]
This tool is used to take online backups and can be used to restore a backup as well.
Available options:
-h, --help          Print this help and exit
-i, --interactive   Interactive mode will prompt user for values instead of assuming defaults ${RED}Not Yet Implemented${NOFORMAT}
-v, --verbose       Print script debug info
-r, --restore YYYYMMDD_HHMMSS
       Restore backup with date/time code of YYYYMMDD_HHMMSS to a PMM server of the same version (.tar.gz file must be in ${backup_root} directory)
-s, --storage	    Choose a different storage location (default: ${backup_root})
-u, --upgrade       Allow restore to a newer PMM server than the backup was taken from (backup and restore version should be 5 or fewer versions apart)
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
    -s | --storage)
      storage="${2-}"
      backup_root="${storage}"
      backup_dir=${backup_root}/${backup_version}
      logfile="${backup_root}/pmmBackup.log"
      msg "${BLUE}Storage override${NOFORMAT} to: ${backup_root}"
      shift
      ;;
    -r | --restore)
      restore="${2-}"
      msg "${BLUE}Restoring${NOFORMAT} ${restore}"
      shift
      ;;
    -u | --upgrade)
      upgrade=true
      msg "${BLUE}Restore${NOFORMAT} to upgraded instance"
      ;;
    -?*) die "Unknown option: ${1}" ;;
    *) break ;;
    esac
    shift
  done

  args=("${@}")

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
  local message=${1}
  local code=${2-1} # default exit status 1
  msg "${message}"
  exit "${code}"
}

#######################################
# Check if Command exists
#######################################

check_command() {
  command -v "${@}" 1>/dev/null
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
      die "${RED}ERROR: root rights needed to run \"${*}\" command ${NOFORMAT}"
    fi
  fi
  ${sh} "${@}" &>>"${logfile}"
}

######################################
# Verify and satisfy prerequisites
######################################
check_prereqs() {

	msg "${ORANGE}Checking${NOFORMAT} for/installing prerequisite software...an internet connection is requried or you must install missing softare manually"
	touch "${logfile}"
	# Does backup location exist and will we be able to write to it
	
	if [ ! -d "${backup_root}" ] ; then 
		if [[ ${UID} -ne 0 ]] ; then
		  sudo mkdir -p "${backup_root}"
		  sudo chown "$(id -un)"."$(id -un)" "${backup_root}"
		else
		  mkdir -p "${backup_root}"
		fi
	elif [ ! -w "${backup_root}" ] ; then 
		die "${RED}${backup_root} is not writable${NOFORMAT}, please look at permissions for $(id -un)"
	fi

	if ! check_command pigz; then
		if ! yum install -y pigz; then
			die "${RED}ERROR ${NOFORMAT}: Could not download needed component...check internet?"
		fi
	fi

	#set version
	if [ "${restore}" == 0 ] ; then
		mkdir -p "${backup_dir}"
		pmm-managed --version 2> >(grep -Em1 ^Version) | sed 's/.*: //' > "${backup_dir}"/pmm_version.txt

		if ! check_command /tmp/vmbackup-prod; then
			get_vm
		fi

	elif [ "${restore}" != 0 ] ; then
		msg "  Extracting Backup Archive"
		restore_from_dir="${backup_root}/pmm_backup_${restore}"
		#msg "restore from dir: ${restore_from_dir}"
		restore_from_file="${backup_root}/pmm_backup_${restore}.tar.gz"
		#msg "restore from file: ${restore_from_file}"
		mkdir -p "${restore_from_dir}"
		tar zxfm "${restore_from_file}" -C "${restore_from_dir}"
		backup_pmm_version=$(cat "${restore_from_dir}"/pmm_version.txt)
		restore_to_pmm_version=$(pmm-managed --version 2> >(grep -Em1 ^Version) | sed 's/.*: //' | awk -F- '{print $1}')
		#msg "from ${backup_pmm_version} to ${restore_to_pmm_version}"
		check_version "${backup_pmm_version}" "${restore_to_pmm_version}"
		#msg "${version_check} for restore action"
		# case eq: versions equal, just go
		# case lt: backup from older version of pmm, needs upgrade flag also
		# case gt: backup from newer version of pmm, not implemented
		if [[ ${version_check} == "eq" ]]; then 
			#good to go, do nothing
			msg "${GREEN}Version Match${NOFORMAT} (${version_check}), proceeding"
		elif [[ ${version_check} == "lt" ]]; then
			if $upgrade ; then
				msg "${GREEN}Proceeding${NOFORMAT} with restore to upgraded version of PMM"
			else
				die "${RED}WARNING${NOFORMAT}: You must also pass the upgrade flag to restore to a newer version of PMM"
			fi
		elif [[ ${version_check} == "gt" ]] ; then
			die "${RED}ERROR${NOFORMAT}: Downgrades are not supported, you can only restore to $backup_pmm_version"
		fi
		
		if ! check_command /tmp/vmrestore-prod; then
			get_vm
		fi
	fi


### nice to haves ###
	#will the backup fit on the filesystem (need >2x the size of the /srv directory)
}

#####################################################
# Do a version check to see if victoriametrics 
# utils are from before windows/linux filename
# designation was added and download as appropriate
#####################################################

get_vm() {
	cd /tmp
	vm_version=$(victoriametrics --version | cut -d '-' -f7 | sed 's/v//')
	check_version "${vm_version}" "1.78.1"
	if [[ ${version_check} == "eq" || ${version_check} == "lt" ]] ; then
		msg "  Old Format location"
		file_name="vmutils-amd64-v${vm_version}.tar.gz"
	elif [[ ${version_check} == "gt" ]]; then
		file_name="vmutils-linux-amd64-v${vm_version}.tar.gz"
	fi
	msg "  Downloading https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/v${vm_version}/${file_name}"
	if ! curl -s -L -O https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/v"${vm_version}"/"${file_name}" &>> "${logfile}" ; then
		die "${RED}ERROR ${NOFORMAT}: Could not download needed component...check internet?"
	fi
	tar zxf "${file_name}"
}

#############################################
# Check to see if version backed up is same, 
# older, newer than version being restored to
#############################################
check_version() {
	#reset version_check to nothing for reuse
	version_check=false
	msg "  Comparing version ${1} to ${2}"
	if [ "${1}" == "${2}" ] ; then
		#versions match, proceed
		version_check="eq"
		return 0
	fi
	local IFS=.
	local i ver1=(${1}) ver2=(${2})
	# fill empty fields in ver1 with zeros
	for ((i=${#ver1[@]}; i<${#ver2[@]}; i++))
	  do
	    ver1[i]=0
	  done

	for ((i=0; i<${#ver1[@]}; i++))
	do
	    if [[ -z ${ver2[i]} ]]
	    then
		# fill empty fields in ver2 with zeros
		ver2[i]=0
	    fi
	    if ((10#${ver1[i]} < 10#${ver2[i]}))
	    then
		version_check="lt"
		return 0
	    fi
	    if ((10#${ver1[i]} > 10#${ver2[i]}))
	    then
		version_check="gt"
		return 0
	    fi
	done
	version_check=false
	return 0

	
	#	if [ "${backup_pmm_version}" != "${restore}_to_pmm_version" ] ; then
	#		die "Cannot restore backup from PMM version ${backup_pmm_version} to PMM version ${restore}_to_pmm_version, install ${backup_pmm_version} on this host and retry."
	#	fi
}

######################################
# Perform Backup of PMM
######################################
perform_backup() {


	#setup env
	msg "${ORANGE}Creating${NOFORMAT} backup directory structure"
	mkdir -p "${backup_root}"/"${backup_version}"/{postgres,vm,clickhouse,folders}


	#pg backup
	msg "${ORANGE}Starting${NOFORMAT} PostgreSQL backup"
	run_root "pg_dump -c -C -U pmm-managed > \"${backup_dir}\"/postgres/backup.sql"
	msg "${GREEN}Completed${NOFORMAT} PostgreSQL backup"

	#vm backup
	msg "${ORANGE}Starting${NOFORMAT} VictoriaMetrics backup"
	run_root "/tmp/vmbackup-prod --storageDataPath=/srv/victoriametrics/data -snapshot.createURL=http://localhost:9090/prometheus/snapshot/create -dst=fs://\"${backup_dir}\"/vm/ -loggerOutput=stdout"
	msg "${GREEN}Completed${NOFORMAT} VictoriaMetrics backup"

	#clickhouse Backup

	msg "${ORANGE}Starting${NOFORMAT} Clickhouse backup"
	mapfile -t ch_array < <(/bin/clickhouse-client --host=127.0.0.1 --query "select name from system.tables where database = '"${clickhouse_database}"'")
	for table in "${ch_array[@]}"
	do
		if [ "${table}" == "schema_migrations" ] ; then
			msg "  Backing up ${table} table"
			/bin/clickhouse-client --host=127.0.0.1 --database "${clickhouse_database}" --query="SHOW CREATE TABLE ${table}" --format="TabSeparatedRaw" > "${backup_dir}"/clickhouse/"${table}".sql
			/bin/clickhouse-client --host=127.0.0.1 --database "${clickhouse_database}" --query="SELECT * from ${table}" --format CSV > "${backup_dir}"/clickhouse/"${table}".data
		else
			msg "  Backing up ${table} table"
			/bin/clickhouse-client --host=127.0.0.1 --database "${clickhouse_database}" --query="SHOW CREATE TABLE ${table}" --format="TabSeparatedRaw" > "${backup_dir}"/clickhouse/"${table}".sql
			/bin/clickhouse-client --host=127.0.0.1 --query "alter table ${clickhouse_database}.${table} freeze"
		fi
	done
		run_root "mv /srv/clickhouse/shadow \"${backup_dir}\"/clickhouse/\"${backup_version}\""
	msg "${GREEN}Completed${NOFORMAT} Clickhouse backup"

	#support files backup
	msg "${ORANGE}Starting${NOFORMAT} configuration and supporting files backup"

	run_root "cp -af /srv/alerting \"${backup_dir}\"/folders/"
	run_root "cp -af /srv/alertmanager \"${backup_dir}\"/folders/"
	run_root "cp -af /srv/grafana \"${backup_dir}\"/folders/"
	run_root "cp -af /srv/nginx \"${backup_dir}\"/folders/"
	run_root "cp -af /srv/prometheus \"${backup_dir}\"/folders/"
	run_root "cp -af /srv/pmm-distribution \"${backup_dir}\"/folders/"

	msg "${GREEN}Completed${NOFORMAT} configuration and supporting files backup"

	msg "${ORANGE}Compressing${NOFORMAT} backup artifact"
	cpus=$(cat /proc/cpuinfo | grep processor | wc -l)
	[ ${cpus} -eq 1 ] && use_cpus=${cpus} || use_cpus=$((${cpus}/2))
	#msg "limiting to ${use_cpus}"
	#run_root "tar -cf "$backup_root"/"$backup_version".tar.gz -C "$backup_dir" ."
	#run_root "tar --use-compress-program=\"pigz -5 -p${use_cpus}\" -cf ${backup_root}/${backup_version}.tar.gz -C ${backup_dir} ."
	run_root "tar -C ${backup_dir} -cf - . | nice pigz -p ${use_cpus} > ${backup_root}/${backup_version}.tar.gz "
	msg "  Cleaning up"
	run_root "rm -rf \"${backup_dir}\""
	msg "\n${GREEN}SUCCESS${NOFORMAT}: Backup Complete"
}


######################################
# Perform Restore of PMM
######################################
perform_restore() {

	#stop pmm-managed locally to restore data
	msg "${ORANGE}Stopping${NOFORMAT} services to begin restore"
	run_root "supervisorctl stop alertmanager grafana nginx pmm-agent pmm-managed qan-api2"
	sleep 5
	msg "  Services stopped, restore starting"
	
	#pg restore
	msg "${ORANGE}Starting${NOFORMAT} PostgreSQL restore"
	psql -U postgres -f "${restore_from_dir}"/postgres/backup.sql &>>"${logfile}"
	msg "${GREEN}Completed${NOFORMAT} PostgreSQL restore"

	#vm restore
	msg "${ORANGE}Starting${NOFORMAT} VictoriaMetrics restore"
	run_root "supervisorctl stop victoriametrics"
	run_root "/tmp/vmrestore-prod -src=fs:///\"${restore_from_dir}\"/vm/ -storageDataPath=/srv/victoriametrics/data"
	run_root "chown -R pmm.pmm /srv/victoriametrics/data"
	run_root "supervisorctl start victoriametrics"
	msg "${GREEN}Completed${NOFORMAT} VictoriaMetrics restore"
	

	#clickhouse restore
	msg "${ORANGE}Starting${NOFORMAT} Clickhouse restore"
	#stop qan api
	#run_root "supervisorctl stop qan-api2"
	#will need to loop through ${table}
	mapfile -t ch_array < <(ls "${restore_from_dir}"/clickhouse | grep .sql | sed "s/\.sql//")
	for table in "${ch_array[@]}"; do
		if [ "${table}" == "schema_migrations" ] ; then
			# schema_migrations only needs SQL replay, other tables need data copies and reattaching files
			msg "  Restoring ${table} table"
			/bin/clickhouse-client --host=127.0.0.1 --database "${clickhouse_database}" --query="drop table if exists ${table}"
			cat "${restore_from_dir}"/clickhouse/"${table}".sql | /bin/clickhouse-client --host=127.0.0.1 --database "${clickhouse_database}"
			# this can be improved as all the data to form this statement is in ${table}.sql and will
			# be a bit more future-proofed if table structure changes
			cat "${restore_from_dir}"/clickhouse/"${table}".data | /bin/clickhouse-client --host=127.0.0.1 --database "${clickhouse_database}" --query "INSERT INTO ${clickhouse_database}.${table} SELECT version, dirty, sequence FROM input('version UInt32, dirty UInt8, sequence UInt64') FORMAT CSV"
			#check that num rows in == num rows inserted
			rows_in=$(/bin/wc -l "${restore_from_dir}"/clickhouse/"${table}".data | cut -d " " -f1)
			rows_inserted=$(clickhouse-client --host=127.0.0.1 --database "${clickhouse_database}" --query="select count(*) from ${table}")
			if [ "${rows_in}" == "${rows_inserted}" ] ; then
				msg "  Successfully restored ${table}"
			else
				msg "  There was a problem restoring ${table}, ${rows_in} rows backed up but ${rows_inserted} restored"
			fi
		else
			msg "  Restoring ${table} table"
			/bin/clickhouse-client --host=127.0.0.1 --database "${clickhouse_database}" --query="drop table if exists ${table}"
			cat "${restore_from_dir}"/clickhouse/"${table}".sql | /bin/clickhouse-client --host=127.0.0.1 --database "${clickhouse_database}"
			[ ! -d "/srv/clickhouse/data/${clickhouse_database}/${table}/detached" ] && run_root "mkdir -p /srv/clickhouse/data/\"${clickhouse_database}\"/\"${table}\"/detached/"
			msg "  Copying files"
			folder=$(cat "${restore_from_dir}"/clickhouse/pmm_backup_"${restore}"/increment.txt)
			if [ $(stat -c %d "${backup_root}") = $(stat -c %D "/srv/clickhouse") ]; then
				run_root "cp -rlf \"${restore_from_dir}\"/clickhouse/pmm_backup_\"${restore}\"/\"$folder\"/data/\"${clickhouse_database}\"/\"${table}\"/* /srv/clickhouse/data/\"${clickhouse_database}\"/\"${table}\"/detached/"
			else 
				run_root "cp -rf \"${restore_from_dir}\"/clickhouse/pmm_backup_\"${restore}\"/\"$folder\"/data/\"${clickhouse_database}\"/\"${table}\"/* /srv/clickhouse/data/\"${clickhouse_database}\"/\"${table}\"/detached/"
			fi
			msg "  Gathering partitions"
			[[ ${UID} -ne 0 ]] && run_root "chmod -R o+rx /srv/clickhouse";
			mapfile -t partitions < <(ls /srv/clickhouse/data/"${clickhouse_database}"/"${table}"/detached/ | cut -d "_" -f1 | uniq)
			[[ ${UID} -ne 0 ]] &&run_root "chmod -R o-rx /srv/clickhouse";
			for partition in "${partitions[@]}"; do
				msg "    Loading partition ${partition}"
				/bin/clickhouse-client --host=127.0.0.1 --database "${clickhouse_database}" --query="alter table ${table} attach partition ${partition}"
			done
		fi
	done


	msg "${GREEN}Completed${NOFORMAT} Clickhouse restore"

	#support files restore
	msg "${ORANGE}Starting${NOFORMAT} configuration and file restore"
	#/srv/alerting (root,root)
	run_root "rm -rf /srv/alerting"
	run_root "cp -af \"${restore_from_dir}\"/folders/alerting/ /srv/alerting"
	run_root "chown -R root.root /srv/alerting"
	#/srv/alertmanager (pmm,pmm)
	run_root "rm -rf /srv/alertmanager"
	run_root "cp -af \"${restore_from_dir}\"/folders/alertmanager/ /srv/alertmanager"
	run_root "chown -R pmm.pmm /srv/alertmanager"
	#/srv/grafana (grafana,grafana)
	run_root "rm -rf /srv/grafana"
	run_root "cp -af \"${restore_from_dir}\"/folders/grafana/ /srv/grafana"
	run_root "chown -R grafana.grafana /srv/grafana"
	#/srv/nginx (root,root)
	run_root "rm -rf /srv/nginx"
	run_root "cp -af \"${restore_from_dir}\"/folders/nginx/ /srv/nginx"
	run_root "chown -R root.root /srv/nginx"
	#/srv/prometheus (pmm,pmm)
	run_root "rm -rf /srv/prometheus"
	run_root "cp -af \"${restore_from_dir}\"/folders/prometheus/ /srv/prometheus"
	run_root "chown -R pmm.pmm /srv/prometheus"
	#/srv/pmm-distribution (root,root) (optional)
	run_root "rm -f /srv/pmm-distribution"
	run_root "cp -af \"${restore_from_dir}\"/folders/pmm-distribution /srv/"
	run_root "chown -R root.root /srv/pmm-distribution"

	#last step
		

	msg "  Restarting servies"
	if ${upgrade} ; then 
		run_root "supervisorctl reload"
		sleep 10
		run_root "supervisorctl reload"
	else
		#run_root "supervisorctl restart grafana nginx pmm-managed qan-api2"
		run_root "supervisorctl start alertmanager grafana nginx pmm-agent pmm-managed qan-api2"
	fi
	msg "${GREEN}Completed${NOFORMAT} configuration and file restore"

	# cleanup
	run_root "rm -rf \"${restore_from_dir}\""
}

main() {
	check_prereqs
	if [ "${restore}" != 0 ]; then
		#do restore stuff here
		msg "  Restoring backup pmm_backup_${restore}.tar.gz"
		perform_restore
	else
		perform_backup
	fi
	
}

setup_colors
parse_params "${@}"
main
die "Thank you for using the PMM Backup Tool!" 0

