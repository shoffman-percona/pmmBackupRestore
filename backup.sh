#prereqs
yum install -y wget
victoriametrics --version | cut -d '-' -f7
wget https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/v1.77.1/vmutils-amd64-v1.77.1.tar.gz
tar zxvf vmutils-amd64-v1.77.1.tar.gz




#pg backup
pg_dump -c -U pmm-managed > /tmp/backup.sql


#vm backup
./vmbackup-prod --storageDataPath=/srv/victoriametrics/data -snapshot.createURL=http://localhost:9090/prometheus/snapshot/create -dst=fs:///srv/backup/vm/

#clickhouse Backup
clickhouse-client --host=127.0.0.1 --query "select name from system.tables where database = 'pmm'"
echo -n 'alter table pmm.metrics freeze' | clickhouse-client --host=127.0.0.1
clickhouse-client --database "pmm" --query="SHOW CREATE TABLE $table" --format="TabSeparatedRaw" | tee $TARGET_BACKUP_LOCATION/$table.sql
mkdir /srv/backup/clickhouse
mv /srv/clickhouse/shadow /srv/backup/clickhouse/backup_name
#loop through # of tables


#support files backup
/srv/alerting (root,root)
/srv/alertmanager (pmm,pmm)
/srv/grafana (grafana,grafana)
/srv/ia (root,root)
/srv/nginx (root,root)
/srv/prometheus (pmm,pmm)
/srv/pmm-distribution (root,root) (optional)










#pg restore
psql -U pmm-managed -f /tmp/backup.sql


#vm restore
./vmrestore-prod -src=fs:///srv/backup/vm/ -storageDataPath=/srv/victoriametrics/data

#clickhouse restore
#will need to loop through #tablenames
cat $tablename.sql | clickhouse-client --host=127.0.0.1 --database pmm
mv $SOURCE_BACKUP_LOCATION/data/pmm/$tablename/* /srv/clickhouse/data/pmm/$tablename/detached/
clickhouse-client --database pmm --query "ALTER TABLE $tablename ATTACH PARTITION 202111"

#support files restore


#last step
supervisorctl restart pmm-managed postgresql clickhouse victoriametrics grafana nginx alertmanager qan-api2 vmalert
