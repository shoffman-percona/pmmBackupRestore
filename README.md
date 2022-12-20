# pmmBackupRestore
The PMM Backup and Restore script is designed for anyone that wants to take full backups of their PMM servers configuration and metrics data as well as be able to easily restore the data in the event of a disaster or failed upgrade.  It is designed to work while your PMM server is running so no need to stop PMM to take backups. 

# How to run - Backup
Running the script is as simple as downloading the backup.sh script, storing it somewhere inside your docker container, AMI, or OVF and running by hand or as a nightly cron job. 
* `curl` or `wget` the full script inside the PMM server/container
* make the file executable (`chnod +x /path/to/backup.sh`)
* run the file `/path/to/backup.sh`
* backup artifacts are stored in the /srv/backups directory

You should know:
* You will need at least 2x the amount of space you're consuming in /srv (the script writes to /srv/backups but you can edit this in the script to store elsewhere)
* There are additional files needed that aren't shipped with PMM so your PMM server will need to be able access the internet to download or you will need to manually download and stage the vmbackup and vmrestore script. 
* If you run this as a cron job, you'll need to clean up the backup artifacts as part of your job or you can run out of storage keeping all versions


# How to run - Restore
The same script can be used to restore the data taken from teh backup process and will handle all the data, permissions, and cleanup.  If you're restoring to a different server you will first need to download and stage the file using on your target PMM server
* `curl` or `wget` the full script inside the PMM server/container
* make the file executable (`chnod +x /path/to/backup.sh`)
* run the restore `/path/to/backup.sh --restore YYYYMMDD_HHMMSS` (where the YYYYMMDD_HHMMSS comes from the backup file you wish to restore in the format pmm_backup_YYYYMMDD_HHMMSS.tar.gz)

You should know:
* You can only restore to the same PMM version the backup was taken from
* You will need at least 2x the amount of space to extract the backup artifact and restore the data
* The PMM Server will shut down services to prevent any metrics ingestion while restoring the backup
* If you're restoring to a remote server (in a DR scenario), new metrics will not start appearing until clients are pointed to the new server
* The home dashboard will not show the correct client count as this is based off of reporting nodes and not just registrations, you can verify data restored by looking at Inventory or looking at any of the technology dashboards with the time range set to a window from when the backup was taken i.e. a 2 day old backup would need the time range set to at least 'last 3 days' to see the metrics.  
