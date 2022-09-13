#!/bin/bash

########################################################################################

VERSION="1.0.11"
CONFIGFILE=/opt/remote-rsync-backup/backup.config
AGENT=$(rsync --version|grep "version "|awk -F'version' '{print $2}'|awk '{print $1}')

########################################################################################

. $CONFIGFILE

export LANG=de_DE.UTF-8

MAILNAME=$(cat /etc/mailname);

# debug mode
DEBUG=0

if pidof -o $$ -x "backup-rsync-remote.sh"; then
 echo "Process already running"
 exit
fi

# parameter --init-ext4 -> initialize (format) new backup disk
if [ "$1" == "--init-ext4" ] && [ "$BACKUPDEV" ]; then
        echo -e -n "Are you sure you want to format this disk?\nAll data on the disk will be lost?! ($BACKUPDEV)\n[Y/N]"
        read ANSWER
        ANSWER=${ANSWER^^}
        if [ "$ANSWER" == "Y" ]; then
                mkfs.ext4 -f $BACKUPDEV
                tune2fs -c $MAXFSCK -i $MAXFSCK $BACKUPDEV
                mount $BACKUPDEV $BACKUPDIR
                ISMOUNTED=$(mount |grep " $BACKUPDEV "|awk '{print $3}'|grep "$BACKUPDIR")
                if [ "$ISMOUNTED" ]; then
                        touch $BACKUPDIR/mounted
                        # get highest number from STATDIR sub-directories
                        if [ -d "$STATDIR" ]; then
                                GETHDID=$(for I in $(ls -d1 $STATDIR/*/|sort);do basename $I;done|awk '/^[0-9]/ { print $1; }'|tail -1)
                                NEWHDID=$((GETHDID+1))
                        else
                                NEWHDID=1
                        fi
                        echo $NEWHDID > "$BACKUPDIR/HDID"
                fi
        fi
        echo "Disk is ready for backup!"
        exit
fi

# if filesystem type is zfs then check for zfstools
ZFS=$(type -p zfs)
if [ "$FSBACKUPDEV" == "zfs" ] && [ ! "$ZFS" ]; then
        echo "Filesystem type for backup disk is zfs but no zfs installed!"
        exit
fi

# if filesystem type is zfs then check for rsyncbackup pool status
if [ "$FSBACKUPDEV" == "zfs" ]; then
        # pool I/O is currently suspended
        ZFSBAD=$(zpool status rsyncbackup 2>/dev/null|grep "pool I/O is currently suspended")
        if [ "$ZFSBAD" ]; then
                echo "ZFS pool rsyncbackup is in bad state - I/O currently suspended! (zpool status rsyncbackup)"
                echo -e "use \"zpool clear -nFX rsyncbackup\" and \"zpool scrub rsyncbackup\" to resolv problems"
                exit
        fi
fi

# parameter --init-zfs -> initialize (format) new backup disk
if [ "$1" == "--init-zfs" ] && [ "$BACKUPDEV" ]; then
        echo -e -n "Are you sure you want to format this disk?\nAll data on the disk will be lost?! ($BACKUPDEV)\n[Y/N]"
        read ANSWER
        ANSWER=${ANSWER^^}
        if [ "$ANSWER" == "Y" ]; then
                zpool create -m $BACKUPDIR -f rsyncbackup $BACKUPDEV
                ISMOUNTED=$(mount |grep "^rsyncbackup"|awk '{print $3}'|grep "$BACKUPDIR")
                if [ "$ISMOUNTED" ]; then
                        touch $BACKUPDIR/mounted
                        # get highest number from STATDIR sub-directories
                        if [ -d "$STATDIR" ]; then
                                GETHDID=$(for I in $(ls -d1 $STATDIR/*/|sort);do basename $I;done|awk '/^[0-9]/ { print $1; }'|tail -1)
                                NEWHDID=$((GETHDID+1))
                        else
                                NEWHDID=1
                        fi
                        echo $NEWHDID > "$BACKUPDIR/HDID"
                fi
                zfs umount -f $BACKUPDIR
        fi
        echo "Disk is ready for backup!"
        exit
fi

# check for new version

if [ "X$SKIPVERSIONCHECK" == "X0" ]; then
        CURL=$(type -p curl)
        if [ "$CURL" ]; then
                AKTVERSION=$($CURL -m2 -f -s https://www.grufo.com/rsync_mail.version)
                if [ "$AKTVERSION" ]; then
                        if [ ! "$VERSION" == "$AKTVERSION" ]; then
                                AKTVERSION="\(new Rsync-Mail version $AKTVERSION available\)"
                        else
                                AKTVERSION=""
                        fi
                fi
        else
                AKTVERSION="\(you need curl to use the upgrade check, please install\)"
        fi
else
        VERSION="$VERSION \(upgrade check disabled\)"
fi

# functions to calc kb, mb, gb, tb
function bytes_for_humans {
        local -i bytes=$1;
        if [[ $bytes -lt 1024 ]]; then
                H="${bytes} B"
        elif [[ $bytes -lt 1048576 ]]; then
                H="$(( (bytes + 1023)/1024 )) KB"
        elif [[ $bytes -lt 1073741824 ]]; then
                H="$(( (bytes + 1048575)/1048576 )) MB"
        elif [[ $bytes -lt 1099511627776 ]]; then
                H="$(( (bytes + 1073741824)/1073741825 )) GB"
        else
                H="$(( (bytes + 1099511627776)/1099511627777 )) TB"
        fi
        echo $H
}

function kbytes_for_humans {
        local -i kbytes=$1;
        if [[ $kbytes -lt 1024 ]]; then
                H=$(echo "scale=2; $kbytes"|bc)" KB"
        elif [[ $kbytes -lt 1048576 ]]; then
                H=$(echo "scale=2; $kbytes/1024"|bc)" MB"
        elif [[ $kbytes -lt 1073741824 ]]; then
                H=$(echo "scale=2; $kbytes/1048576"|bc)" GB"
        elif [[ $kbytes -lt 1099511627776 ]]; then
                H=$(echo "scale=2; $kbytes/1073741825"|bc)" TB"
        else
                H=$(echo "scale=2; $kbytes/1099511627777"|bc)" PB"
        fi
        echo $H
}

# mount backup disk
if [ "X$DEBUG" == "X1" ]; then echo "mount backupdir"; fi

if ! [ -d "$BACKUPDIR" ]; then
        mkdir $BACKUPDIR
fi

if ! [ -d "$STATDIR" ]; then
        mkdir $STATDIR
fi

MAILNAME=$(cat /etc/mailname);

if [ "$FSBACKUPDEV" == "zfs" ]; then
        ISMOUNTED=$(mount |grep "^rsyncbackup"|awk '{print $3}'|grep "$BACKUPDIR")
else
        ISMOUNTED=$(mount |grep " $BACKUPDEV "|awk '{print $3}'|grep "$BACKUPDIR")
fi

if [ "X$DEBUG" == "X1" ]; then echo "check mounted backupdir"; fi

if [ "$BACKUPDEV" ]; then
        if [ "$FSBACKUPDEV" == "ext4" ]; then
                MCOUNT=$(tune2fs -l $BACKUPDEV 2>/dev/null|grep "^Mount count:"|awk -F':' '{print $2}'| sed -e "s/ //g")
        fi
        if ! [ -f "$BACKUPDIR/mounted" ]; then
                if [ -f "$STATDIR/fsck.log" ]; then rm "$STATDIR/fsck.log";fi
                if [ $MCOUNT ] && [ $MCOUNT -gt $MAXFSCK ]; then
                        if [ "X$DEBUG" == "X1" ]; then echo "do filesystem check"; fi
                        FSCKSTATUS=$(fsck.ext4 -p $BACKUPDEV > $STATDIR/fsck.log)
                fi
                if ! [ "$ISMOUNTED" ]; then
                        if [ "$FSBACKUPDEV" == "zfs"  ]; then
                                if [ "X$DEBUG" == "X1" ]; then echo "import zfs"; fi
                                zpool import -N rsyncbackup 2>/dev/null
                                zfs mount rsyncbackup 2>/dev/null
                        else
                                mount -t $FSBACKUPDEV $BACKUPDEV $BACKUPDIR > /dev/null
                        fi
                else
                        # file "mounted" is missing: if HDID file missing too create new HDID and mounted
                        if [ ! -f "$BACKUPDIR/HDID" ]; then
                                if [ "X$DEBUG" == "X1" ]; then echo "check hdid or create new"; fi
                                touch "$BACKUPDIR/mounted"
                                # get highest number from STATDIR sub-directories
                                GETHDID=$(for I in $(ls -d1 $STATDIR/*/|sort);do basename $I;done|awk '/^[0-9]/ { print $1; }'|tail -1)
                                NEWHDID=$((GETHDID+1))
                                echo $NEWHDID > "$BACKUPDIR/HDID"
                                # set fsck-interval to MAXFSCK (only ext4)
                                if [ "$FSBACKUPDEV" == "ext4" ]; then
                                        tune2fs -c $MAXFSCK -i $MAXFSCK $BACKUPDEV
                                fi
                        fi
                fi
        fi

        if ! [ -f "$BACKUPDIR/mounted" ]; then
                sleep 10
                if [ "$FSBACKUPDEV" == "zfs"  ]; then
                        zfs mount rsyncbackup 2>/dev/null
                else
                        mount -t $FSBACKUPDEV $BACKUPDEV $BACKUPDIR > /dev/null
                fi
        fi

        if [ ! -f "$BACKUPDIR/mounted" ]; then
                if [ "X$DEBUG" == "X1" ]; then echo "backup disk not mounted"; fi
                MNTERR="ERROR: Backup disk not mounted!"
                STATE=999
        fi

fi

if [ -f "$BACKUPDIR/mounted" ]; then
        # read active and last HDID
        if [ -f "$BACKUPDIR/HDID" ]; then
                HDID=$(cat $BACKUPDIR/HDID)
        fi
        LASTHD=$(cat $STATDIR/LASTHD)

        if [ "$HDID" ]; then
                # check HDID if changed start with 1 otherwise count up
                if ! [ "$HDID" == "$LASTHD" ]; then
                        echo $HDID > $STATDIR/LASTHD
                        echo 1 > $STATDIR/ANZAHL
                        ANZAHL=1
                else
                        ANZAHL=`cat $STATDIR/ANZAHL`
                        ANZAHL=$((ANZAHL+1))
                        echo $ANZAHL > $STATDIR/ANZAHL
                fi

                if [ "X$DEBUG" == "X1" ]; then echo "check for days to disk change"; fi
                if [ "$HDCHANGEMAIL" == "1" ]; then
                        if [ "$ANZAHL" -gt "$HDCHANGEDAYS" ]; then
                                (
                                echo "Hard disk no. $HDID has been connected for $ANZAHL days!"
                                echo "Please replace the backup hard disk immediately."
                                echo " "
                                ) | mail -s "REMINDER: change backup disk" $HDCHANGEMAILTO
                        fi
                fi

                # create new stats-directory for new HDID
                if ! [ -d "$STATDIR/$HDID" ]; then
                        mkdir $STATDIR/$HDID
                fi
        fi

fi

HEUTE=$(date +'%Y-%m-%d')

if [ "$1" ]; then
        ONLY="grep $1"
else 
        ONLY="cat"
fi

for LINE in $(cat $SOURCEFILE|grep -v "^#"|$ONLY);do

 ERRLOG=""

        # set daten/time variable
        BSTART=$(date)
        START=$(date +"%A, %d %B %Y %H:%M:%S")
        STIME=$(date +"%H:%M:%S")
        STARTSEC=$(date +"%s")

        SERVER=$(echo $LINE|awk -F'|' '{print $1}')
        TARGET=$(echo $LINE|awk -F'|' '{print $2}')
        MAX=$(echo $LINE|awk -F'|' '{print $3}')
        EXCLUDES=$(echo $LINE|awk -F'|' '{print $4}')
        SSHPORT=$(echo $LINE|awk -F'|' '{print $5}')
        MAX1=$((MAX+1))

        if [ "X$DEBUG" == "X1" ]; then echo "create backup for $SERVER"; fi

        if [ -f "$BACKUPDIR/mounted" ]; then

                if [ -f "$STATDIR/$HDID/$SERVER.log" ]; then
                        cp $STATDIR/$HDID/$SERVER.log $STATDIR/$HDID/$SERVER.log.last
                fi
                date > $STATDIR/$HDID/$SERVER.log

                # create backup directory
                if [ "$FSBACKUPDEV" == "zfs" ]; then
                        zfs mount rsyncbackup/$SERVER 2>/dev/null
                        if [ ! -d "$TARGET/$SERVER" ]; then
                                echo "Creating new backup directory for server $SERVER" >> $STATDIR/$HDID/$SERVER.log
                                zfs create rsyncbackup/$SERVER >> $STATDIR/$HDID/$SERVER.log
                                zfs set compression=lz4 rsyncbackup
                        fi
                else
                        if [ ! -d "$TARGET/$SERVER" ]; then
                                echo "Creating new backup directory for server $SERVER" >> $STATDIR/$HDID/$SERVER.log
                                mkdir "$TARGET/$SERVER" >> $STATDIR/$HDID/$SERVER.log
                        fi
                fi

                # check free space
                GETPERCENTAGE='s/.* \([0-9]\{1,3\}\)%.*/\1/'
                KBISFREE=$(df "$TARGET" | tail -n1 | sed -e "$GETPERCENTAGE")
                if [ $KBISFREE -ge $HDMINFREE ] ; then
                        echo "Fatal: Not enough space left for rsyncing backups!" >> $STATDIR/$HDID/$SERVER.log
                        logger "Fatal: Not enough space left for rsyncing backups!"
                        exit
                fi

                # check if host is alive?
                if [ "$SSHPORT" ]; then
                        ALIVE=$(ssh -p $SSHPORT $SERVER "hostname" 2>/dev/null)
                else
                        ALIVE=$(ssh $SERVER "hostname")
                fi

                if [ "$ALIVE" ]; then
                        # rsync local or remote (ssh-port)

                        if [ "$FSBACKUPDEV" == "zfs" ]; then
                                if [ "$SSHPORT" ]; then
                                        rsync -avz --numeric-ids -e "ssh -p $SSHPORT" --delete --delete-excluded --exclude-from="$EXCLUDES" $SERVER:/ $TARGET/$SERVER/ >> $STATDIR/$HDID/$SERVER.log 2>&1
                                else
                                        # backup local system
                                        rsync -avz --numeric-ids --delete --delete-excluded --exclude-from="$EXCLUDES" / $TARGET/$SERVER/ >> $STATDIR/$HDID/$SERVER.log 2>&1
                                fi
                        else
                                if [ "$SSHPORT" ]; then
                                        rsync -avz --numeric-ids -e "ssh -p $SSHPORT" --delete --delete-excluded --exclude-from="$EXCLUDES" $SERVER:/ $TARGET/$SERVER/daily.0/ >> $STATDIR/$HDID/$SERVER.log 2>&1
                                else
                                        # backup local system
                                        rsync -avz --numeric-ids --delete --delete-excluded --exclude-from="$EXCLUDES" / $TARGET/$SERVER/daily.0/ >> $STATDIR/$HDID/$SERVER.log 2>&1
                                fi
                        fi

                        STATE=$?

                        echo $HEUTE > $TARGET/$SERVER/sicherungs.datum

                        grep "error (" $STATDIR/$HDID/$SERVER.log > $STATDIR/$HDID/$SERVER.error
                        grep "file has vanished" $STATDIR/$HDID/$SERVER.log > $STATDIR/$HDID/$SERVER.warning

                else
                        STATE=998
                        echo "Fatal: Host offline!" > $STATDIR/$HDID/$SERVER.log
                        logger "Fatal: Host offline! ($SERVER)"
                fi
        fi

        END=$(date +"%A, %d.%m.%Y %H:%M:%S")
        ETIME=$(date +"%H:%M:%S")
        ENDSEC=$(date +"%s")

        DURATION=$(date -d "0 $ENDSEC sec - $STARTSEC sec" +"%H:%M:%S")
        DSEC=$(($ENDSEC-$STARTSEC))

        if [ "X$DEBUG" == "X1" ]; then echo "send info mail"; fi
        # send info mail

        if [ "$STATE" == "0" ]; then SUCCESS=1; BGCOLOR="#00B050"; STAT="Success"; else SUCCESS=0; fi
        if [ -f "$STATDIR/$HDID/$SERVER.error" ]; then
        ERRLOG=$(cat $STATDIR/$HDID/$SERVER.error|sed ':a;N;$!ba;s/\n/<br>/g')
        fi
        if [ -f "$STATDIR/fsck.log" ]; then ERRLOG="$ERRLOG$(cat $STATDIR/fsck.log)"; fi
        case "$STATE" in
                "1") ERROR=1; BGCOLOR="#fb9895"; STAT="Failed"; ERRLOG="$ERRLOG Syntax or usage error";;
                "2") ERROR=1; BGCOLOR="#fb9895"; STAT="Failed"; ERRLOG="$ERRLOG Protocol incompatibility";;
                "3") ERROR=1; BGCOLOR="#fb9895"; STAT="Failed"; ERRLOG="$ERRLOG Errors selecting input/output files, dirs";;
                "4") ERROR=1; BGCOLOR="#fb9895"; STAT="Failed"; ERRLOG="$ERRLOG Requested  action not supported: an attempt was made to manipulate 64-bit files on a platform that cannot support them; or an option was specified that is supported by the client and not by the server.";;
                "5") ERROR=1; BGCOLOR="#fb9895"; STAT="Failed"; ERRLOG="$ERRLOG Error starting client-server protocol";;
                "6") ERROR=1; BGCOLOR="#fb9895"; STAT="Failed"; ERRLOG="$ERRLOG Daemon unable to append to log-file";;
                "10") ERROR=1; BGCOLOR="#fb9895"; STAT="Failed"; ERRLOG="$ERRLOG Error in socket I/O";;
                "11") ERROR=1; BGCOLOR="#fb9895"; STAT="Failed"; ERRLOG="$ERRLOG Error in file I/O";;
                "12") ERROR=1; BGCOLOR="#fb9895"; STAT="Failed"; ERRLOG="$ERRLOG Error in rsync protocol data stream";;
                "13") ERROR=1; BGCOLOR="#fb9895"; STAT="Failed"; ERRLOG="$ERRLOG Errors with program diagnostics";;
                "14") ERROR=1; BGCOLOR="#fb9895"; STAT="Failed"; ERRLOG="$ERRLOG Error in IPC code";;
                "20") ERROR=1; BGCOLOR="#fb9895"; STAT="Failed"; ERRLOG="$ERRLOG Received SIGUSR1 or SIGINT";;
                "21") ERROR=1; BGCOLOR="#fb9895"; STAT="Failed"; ERRLOG="$ERRLOG Some error returned by waitpid()";;
                "22") ERROR=1; BGCOLOR="#fb9895"; STAT="Failed"; ERRLOG="$ERRLOG Error allocating core memory buffers";;
                "23") ERROR=1; BGCOLOR="#fb9895"; STAT="Failed"; ERRLOG="$ERRLOG Partial transfer due to error";;
                "25") ERROR=1; BGCOLOR="#fb9895"; STAT="Failed"; ERRLOG="$ERRLOG The --max-delete limit stopped deletions";;
                "30") ERROR=1; BGCOLOR="#fb9895"; STAT="Failed"; ERRLOG="$ERRLOG Timeout in data send/receive";;
                "35") ERROR=1; BGCOLOR="#fb9895"; STAT="Failed"; ERRLOG="$ERRLOG Timeout waiting for daemon connection";;
                "998") ERROR=1; BGCOLOR="#fb9895"; STAT="Failed"; ERRLOG="Error - Host offline";;
                "999") ERROR=1; BGCOLOR="#fb9895"; STAT="Failed"; ERRLOG="$MNTERR";;
                * ) ERROR=0;;
        esac
        if [ "$STATE" == "24" ]; then
                WARNING=1;
                BGCOLOR="#fbcb95";
                STAT="Warning";
                ERRLOG=$(cat $STATDIR/$HDID/$SERVER.warning|sed ':a;N;$!ba;s/\n/<br>/g')
        else
                WARNING=0;
        fi

        if [ "X$DEBUG" == "X1" ]; then echo "get stats from last backup"; fi

        if [ -f "$BACKUPDIR/mounted" ]; then
                READ=$(grep "^total size is" $STATDIR/$HDID/$SERVER.log|awk '{print $4}'|sed -e "s/,//g")
                TRANSFERRED=$(grep "^sent " $STATDIR/$HDID/$SERVER.log|grep " received "|awk '{print $5}'|sed -e "s/,//g")
                if [ "$TRANSFERRED" ]; then
                 SPEED=$(($TRANSFERRED / $DSEC))
                else SPEED=0
         fi
                SPEED=$(bytes_for_humans "$SPEED")
                if [ "$FSBACKUPDEV" == "zfs" ]; then
                        PROCESSED=$(zfs list -pH rsyncbackup/$SERVER@1|awk '{print $2}')
                else
                        PROCESSED=$(du -sc $TARGET/$SERVER/daily.0/|tail -n1|awk '{print $1}')
                fi
        fi

        if [ "X$DEBUG" == "X1" ]; then echo "get target, filesystem type"; fi

        DTARGET="@$HOSTNAME:/$TARGET/$SERVER"
        FST=$(mount |grep " $TARGET "|head -1|awk '{print $5}')

        if [ "X$DEBUG" == "X1" ]; then echo "get device size, used, avail,..."; fi

        if [ -f "$BACKUPDIR/mounted" ]; then
                if [ "$FSBACKUPDEV" == "zfs" ]; then
                        AVAIL=$(zfs list -Hp rsyncbackup|awk '{print $3}')
                        DEVUSED=$(zfs list -Hp rsyncbackup|awk '{print $2}')
                        DEVSIZE=$(($AVAIL+$DEVUSED))
                        DEVUSEP=$(awk -v "a=$DEVSIZE" -v "b=$AVAIL" 'BEGIN {printf "%.1f\n", (a-b)/a*100}')
                        DEVUSED=$(bytes_for_humans "$DEVUSED")
                        DEVAVAIL=$(bytes_for_humans "$AVAIL")
                        DEVSIZE=$(bytes_for_humans "$DEVSIZE")
                else
                        AVAIL=$(df "$TARGET"|tail -n1|awk '{print $4}')
                        DEVUSED=$(df "$TARGET"|tail -n1|awk '{print $3}')
                        DEVSIZE=$(($AVAIL+$DEVUSED))
                        DEVUSEP=$(awk -v "a=$DEVSIZE" -v "b=$AVAIL" 'BEGIN {printf "%.1f\n", (a-b)/a*100}')
                        DEVUSED=$(kbytes_for_humans "$DEVUSED")
                        DEVAVAIL=$(kbytes_for_humans "$AVAIL")
                        DEVSIZE=$(kbytes_for_humans "$DEVSIZE")
                fi

                READ=$(bytes_for_humans "$READ")
                TRANSFERRED=$(bytes_for_humans "$TRANSFERRED")
                PROCESSED=$(kbytes_for_humans "$PROCESSED")
        fi

        # create temp file for mail
        TEMPFILE=$(mktemp)

        # uppercase hostname
        HN=${SERVER^^}

        if [ "X$DEBUG" == "X1" ]; then echo "build email"; fi

        # build email
        #To: $EMAILTO
        RANDSHA=$(head -1 /dev/urandom|sha256sum|head -c25)
        if [ "$ATTACHLOG" == "1" ]; then
                RANDSHAL=$(head -1 /dev/urandom|sha256sum|head -c25)
                LOGMIME=";\n boundary=\"------------$RANDSHAL\"\nContent-Language: de-AT\n"
                LOGMIME2="\n--------------$RANDSHAL"
        fi

        if [ "X$DEBUG" == "X1" ]; then echo "send mail with attachment"; fi

        if [ "$ATTACHLOG" == "1" ]; then
                echo -e -n "From: $EMAILFROM\nTo: $EMAILTO\nSubject: [$STAT] $HN - $START\nMIME-Version: 1.0\nContent-Type: multipart/mixed$LOGMIME\nThis is a multi-part message in MIME format.$LOGMIME2\nContent-Type: multipart/alternative;\n boundary=\"------------$RANDSHA\"\n\n\n--------------$RANDSHA\nContent-Type: text/html; charset=utf-8\nContent-Transfer-Encoding: 7bit\n\n" > $TEMPFILE
        else
                echo -e -n "From: $EMAILFROM\nTo: $EMAILTO\nSubject: [$STAT] $HN - $START\nMIME-Version: 1.0\nContent-Type: text/html; charset=utf-8\nContent-Transfer-Encoding: 7bit\n\n" > $TEMPFILE

        fi

        # debug output
        #echo -e -n "HN: $HN\nSTAT: $STAT\nBGCOLOR: $BGCOLOR\nSTART: $START\nSUCCESS: $SUCCESS\nERROR: $ERROR\nWARNING: $WARNING\nSTIME: $STIME\nETIME: $ETIME\nREAD: $READ\nTRANSFERRED: $TRANSFERRED\nDURATION: $DURATION\nPROCESSED: $PROCESSED\nBOTTLENECK: $BOTTLENECK\nERRLOG: $ERRLOG\nSPEED: $SPEED\nTARGET: $TARGET\nFST: $FST\nLOGIN: $LOGIN\nDOMAIN: $DOMAIN\n"
        logger -t "RSYNC-BACKUP" "HN: $HN\nSTAT: $STAT\nBGCOLOR: $BGCOLOR\nSTART: $START\nSUCCESS: $SUCCESS\nERROR: $ERROR\nWARNING: $WARNING\nSTIME: $STIME\nETIME: $ETIME\nREAD: $READ\nTRANSFERRED: $TRANSFERRED\nDURATION: $DURATION\nPROCESSED: $PROCESSED\nBOTTLENECK: $BOTTLENECK\nERRLOG: $ERRLOG\nSPEED: $SPEED\nTARGET: $TARGET\nFST: $FST\nLOGIN: $LOGIN\nDOMAIN: $DOMAIN\n"


        sed -e "s/XXXHOSTNAMEXXX/$HN/g" -e "s/XXXSTATXXX/$STAT/g" -e "s/XXXBGCOLORXXX/$BGCOLOR/g" -e "s/XXXBACKUPDATETIMEXXX/$START/g" -e "s/XXXSUCCESSXXX/$SUCCESS/g" -e "s/XXXERRORXXX/$ERROR/g" -e "s/XXXWARNINGXXX/$WARNING/g" -e "s/XXXSTARTXXX/$STIME/g" -e "s/XXXENDXXX/$ETIME/g" -e "s/XXXDATAREADXXX/$READ/g" -e "s/XXXREADXXX/$READ/g" -e "s/XXXTRANSFERREDXXX/$TRANSFERRED/g" -e "s/XXXDURATIONXXX/$DURATION/g" -e "s/XXXSTATUSXXX/$STAT/g" -e "s/XXXTOTALSIZEXXX/$READ/g" -e "s/XXXBOTTLENECKXXX/$BOTTLENECK/g" -e "s|XXXDETAILSXXX|$ERRLOG|g" -e "s/XXXRATEXXX/$SPEED\/s/g" -e "s/XXXBACKUPSIZEXXX/$PROCESSED/g" -e "s/XXXAGENTXXX/$AGENT/g" -e "s|XXXTARGETXXX|$DTARGET|g" -e "s|XXXFSTXXX|$FST|g" -e "s|XXXLOGINXXX|$LOGIN|g" -e "s|XXXDOMAINXXX|$DOMAIN|g" -e "s/XXXVERSIONXXX/$VERSION/g" -e "s/XXXAKTVERSIONXXX/$AKTVERSION/g" -e "s/XXXDISKSIZEXXX/$DEVSIZE/g" -e "s/XXXDISKUSEDXXX/$DEVUSED/g" -e "s/XXXDISKAVAILXXX/$DEVAVAIL/g" -e "s/XXXDISKUSEPXXX/$DEVUSEP/g" $HTMLTEMPLATE >> $TEMPFILE 

        if [ "$ATTACHLOG" == "1" ]; then
                echo -e -n "\n--------------$RANDSHA--\n" >> $TEMPFILE
                if [ -f "$STATDIR/$HDID/$SERVER.log" ]; then
                        echo -e -n "\n\n--------------$RANDSHAL\nContent-Type: text/x-log; charset=UTF-8; name=\"$SERVER.log\"\nContent-Transfer-Encoding: 7bit\nContent-Disposition: attachment;\n filename=\"$SERVER.log\"\n\n" >> $TEMPFILE
                        #cat "$STATDIR/$HDID/$SERVER.log" |uuencode -m /dev/stdout >> $TEMPFILE
                        cat "$STATDIR/$HDID/$SERVER.log" >> $TEMPFILE
                        echo -e -n "\n--------------$RANDSHAL--\n" >> $TEMPFILE
                fi
        fi

        # send email
        cat $TEMPFILE | sendmail -t
        rm $TEMPFILE

        if [ "X$DEBUG" == "X1" ]; then echo "remove, rotate snapshot"; fi

        if [ -f "$BACKUPDIR/mounted" ]; then

                # remove latest snapshot
                if [ "$FSBACKUPDEV" == "zfs" ]; then
                        SNAPMISS=$(zfs list -t snapshot rsyncbackup/$SERVER@$MAX 2>&1|grep "dataset does not exist")
                        if [ ! "$SNAPMISS" ] ; then
                                zfs destroy rsyncbackup/$SERVER@$MAX
                        fi
                else
                        if [ -d "$TARGET/$SERVER/daily.$MAX" ]; then
                                rm -rf "$TARGET/$SERVER/daily.$MAX"
                        fi
                fi

                # rotate snapshots
                for ((OLD=$MAX; OLD >= 1 ; OLD=OLD-1)); do
                        NEW=$[ $OLD + 1 ]
                        if [ "$FSBACKUPDEV" == "zfs" ]; then
                                SNAPMISS=$(zfs list -t snapshot rsyncbackup/$SERVER@$OLD 2>&1|grep "dataset does not exist")
                                if [ ! "$SNAPMISS" ] ; then
                                        zfs rename rsyncbackup/$SERVER@$OLD rsyncbackup/$SERVER@$NEW
                                fi
                        else
                                if [ -d "$TARGET/$SERVER/daily.$OLD" ] ; then
                                        touch "$TARGET/.timestamp" -r "$TARGET/$SERVER/daily.$OLD"
                                        mv "$TARGET/$SERVER/daily.$OLD" "$TARGET/$SERVER/daily.$NEW"
                                        touch "$TARGET/$SERVER/daily.$NEW" -r "$TARGET/.timestamp"
                                fi
                        fi
                done

                # create/copy snapshot from Level-0 with hardlinks to Level-1
                if [ "$FSBACKUPDEV" == "zfs" ]; then
                        zfs snapshot rsyncbackup/$SERVER@1
                else
                        if [ -d "$TARGET/$SERVER/daily.0" ] ; then
                                cp -al "$TARGET/$SERVER/daily.0" "$TARGET/$SERVER/daily.1"
                        fi
                fi
        fi

done

BENDE=$(date)

if [ "X$DEBUG" == "X1" ]; then echo "unmount backup disk"; fi

if [ -f "$BACKUPDIR/mounted" ] && [ "$BACKUPDEV" ]; then
        sync
        sleep 10
        if [ "$FSBACKUPDEV" == "zfs" ]; then
                zfs umount -f $BACKUPDIR
                zpool export rsyncbackup
        else
                umount $BACKUPDIR
        fi
        if [ -f "$BACKUPDIR/mounted" ]; then
                echo "unable to unmount backup disk (busy)..."
        fi
fi
