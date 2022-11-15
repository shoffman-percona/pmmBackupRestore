#!/bin/bash

#vars
backup_version="pmm_backup_$(date +%s)"
backup_root="/srv/backups"
backup_dir=$backup_root/$backup_version


#prereqs

yum install -y wget
cd /tmp
vm_version=`victoriametrics --version | cut -d '-' -f7`
echo "vm version is $vm_version"
wget https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/$vm_version/vmutils-amd64-$vm_version.tar.gz
tar zxvf vmutils-amd64-$vm_version.tar.gz

#setup env
mkdir -p $backup_root/$backup_version/{postgres,vm,clickhouse,folders}


#pg backup
pg_dump -c -U pmm-managed > $backup_dir/postgres/backup.sql


#vm backup
/tmp/vmbackup-prod --storageDataPath=/srv/victoriametrics/data -snapshot.createURL=http://localhost:9090/prometheus/snapshot/create -dst=fs://$backup_dir/vm/

#clickhouse Backup

mapfile -t ch_array < <(/bin/clickhouse-client --host=127.0.0.1 --query "select name from system.tables where database = 'pmm'")
for table in "${ch_array[@]}"
do
        echo "step 1 on $table"
        /bin/clickhouse-client --host=127.0.0.1 --query "alter table pmm.$table freeze" 
        echo "step 2 on $table"
        /bin/clickhouse-client --host=127.0.0.1 --database "pmm" --query="SHOW CREATE TABLE $table" --format="TabSeparatedRaw" > $backup_dir/clickhouse/$table.sql
done
        echo "step 3"
        mv /srv/clickhouse/shadow $backup_dir/clickhouse/$backup_version


#support files backup

cp -af /srv/alerting $backup_dir/folders/
cp -af /srv/alertmanager $backup_dir/folders/
cp -af /srv/grafana $backup_dir/folders/
cp -af /srv/ia $backup_dir/folders/
cp -af /srv/nginx $backup_dir/folders/
cp -af /srv/prometheus $backup_dir/folders/
cp -af /srv/pmm-distribution $backup_dir/folders/



#$/srv/alerting (root,root)
#/srv/alertmanager (pmm,pmm)
#/srv/grafana (grafana,grafana)
#/srv/ia (root,root)
#/srv/nginx (root,root)
#/srv/prometheus (pmm,pmm)
#/srv/pmm-distribution (root,root) (optional)










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


#last step
#supervisorctl restart pmm-managed postgresql clickhouse victoriametrics grafana nginx alertmanager qan-api2 vmalert
