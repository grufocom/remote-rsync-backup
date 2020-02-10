# remote-rsync-backup
Bash script for remote and local rsync backup including support of zfs/ext4 (backup device) and Veeam like mail notifications

This script offers Rsync-backup with Veeam-style mail notification. It creates incremental backups of files and directories to the destination of your choice (local folder or external disk). The backup structure is easy to recover any file at any point in time.

If you install ZFS-Tools you can use the compression of zfs to get more out of your external devices. The main advantage of this script is that it will evaluate the return value from rsync and build a nice info mail with all the nessesary information you need.

## Installation/Usage

    git clone https://github.com/grufocom/remote-rsync-backup/

Move the directory to /opt

    mv remote-rsync-backup /opt

Install zfstools and curl (optional - zfstools if you would like to use zfs with snapshots and compression, curl to check for new versions of remote-rsync-backup)

    sudo apt-get install zfstools curl
or
    sudo yum install curl zfstools
    
Change the default settings in backup.config to your needs.
Change the hosts which you would like to backup in backup-source.config.

Attach your backup disk and initialize it with (zfs is recommended)
    /opt/remote-rsync-backup/backup-rsync-remote.sh --init-zfs
or 
    /opt/remote-rsync-backup/backup-rsync-remote.sh --init-ext4
depending on the filesystem your would like to use.

If you would like to backup a remote system to a local harddisk, your just need enough free space for instance in /srv/backup and you should create the following files manualy:

    touch /srv/backup/mounted
    echo 1 > /srv/backup/HDID
    
If the file "mounted" is not found the backup will not start.

To backup all systems simply start the backup script:

    /opt/remote-rsync-backup/backup-rsync-remote.sh
    
To backup only one specific system start it with the hostname you have used in backup-source.config

    /opt/remote-rsync-backup/backup-rsync-remote.sh hosttobackup
    
To backup your remote or local system you will have to copy your public ssh key to the system you would like to backup: 

    ssh-copy-id hosttobackup
    
Password-less login with ssk-key is mandadory!

To restore files from your backup simply mount the backup device 

    zpool import -N rsyncbackup && zfs mount rsyncbackup

Latest backup can be found in your "BACKUPDIR" for instance /srv/backup.

To get files from a snapshot just list the snapshots with:

        zfs list -t snapshot
        
And mount the one you would like to restore from:
    
    mount -t zfs rsyncbackup/systema@17 /mnt
    
Unmount and detach zfs disk with:

    umount /mnt && zfs umount -f /srv/backup && zpool export rsyncbackup

## TODO

* automatic mount of snapshots for restore
* test ssh connection to backup systems and copy public ssh key to them
* init-local - initialize for backup to local disk
