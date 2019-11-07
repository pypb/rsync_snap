#!/bin/bash

#
# rsync_snap.sh creates rsync snapshot backups (using hardlinks) of remote servers
#

lockfile -r 0 /tmp/.rsync_snap.lck || { echo "ERROR: rsync_snap is already running"; exit 1; }

# read config
test -e ~/.rsync_snap.conf || { echo "ERROR: missing config file"; exit 1; }
declare -A SOURCES
declare -A PRE_SCRIPT
declare -A POST_SCRIPT
source ~/.rsync_snap.conf

test -d $DEST || { echo $DEST does not exist; exit 1; }

# create log & status file
test -e $LOG || { touch $LOG; chmod 600 $LOG; }
test -e /var/tmp/.rsync_snap.status || touch /var/tmp/.rsync_snap.status

STATUS=0
TS=$(date +%Y%m%d_%H%M)
TS_SECS=$(date +%s)

# disable wildcard expansion
set -f

# concatenate excludes from config
EXCL_ARGS=""
for PATTERN in $EXCLUDE; do
  EXCL_ARGS="$EXCL_ARGS --exclude '$PATTERN'"
done

# run rsync
echo "$(date -R) *** starting rsync_snap" >> $LOG

for HOST in "${!SOURCES[@]}"; do
  echo "$(date -R) [$HOST] processing" >> $LOG

  # setup environment
  RSYNC="rsync -ahix -zz --noatime --numeric-ids --outbuf=N --relative --stats -e 'ssh -i/root/.ssh/snapbackup_id_ed25519 -caes128-ctr -oStrictHostKeyChecking=accept-new -oBatchMode=yes' \
    --exclude '*/.ansible/' \
    --exclude '*/.cache/' \
    --exclude '*/.snapshots/' \
    --exclude '/dev/' \
    --exclude '/media/' \
    --exclude '/mnt/' \
    --exclude '/proc/' \
    --exclude '/run/' \
    --exclude '/sys/' \
    --exclude '/tmp/' \
    --exclude '/var/cache/' \
    --exclude '/var/run/' \
    --exclude '/var/swap' \
    --exclude '/var/tmp/' \
    $EXCL_ARGS \
  "

  BACKUP_HOST="$DEST/${HOST%%.*}"
  BACKUP_DEST="$BACKUP_HOST/$TS"
  BACKUP_LATEST="$BACKUP_HOST/latest"
  
  # append link-dest to rsync
  if [ -e $BACKUP_LATEST ]; then
    RSYNC="$RSYNC --link-dest=$BACKUP_LATEST"
    LAT="$(basename $(readlink -f $BACKUP_LATEST))"
    AGE=$(expr $TS_SECS - $(date -r $BACKUP_LATEST +%s))

    echo "$(date -R) [$HOST] latest snapshot is $LAT ($AGE seconds old)" >> $LOG

    if [ "$AGE" -lt "$AGE_MIN" ]; then
      echo "$(date -R) [$HOST] skipping, snapshot less than $AGE_MIN seconds old" >> $LOG
      continue
    fi

  else
    echo "$(date -R) [$HOST] no previous snapshot found, this will be a full backup" >> $LOG
  fi

  # append paths to command
  for p in ${SOURCES[$HOST]}; do
    RSYNC="$RSYNC $HOST:$p/"
  done

  # append destination to command
  RSYNC="$RSYNC $BACKUP_DEST/"

  if [ ! -z "${PRE_SCRIPT[$HOST]}" ]; then
    echo "$(date -R) [$HOST] running pre-script ${PRE_SCRIPT[$HOST]}" >> $LOG
    eval ${PRE_SCRIPT[$HOST]} >> $LOG 2>&1
  fi

  # if pre-script ok
  if [ $? -eq 0 ]; then
    echo "$(date -R) [$HOST] backing up to $BACKUP_DEST" >> $LOG

    mkdir -p $BACKUP_DEST

    echo "+ $RSYNC" >> $LOG
    eval $RSYNC >> $LOG 2>&1
    ec=$?
    echo "ec: $ec" >> $LOG

    # if backup was successful, do some cleaning
    if [ $ec -eq 0 ] || [ $ec -eq 24 ]; then
      echo "$(date -R) [$HOST] backup successful, updating latest link" >> $LOG
      touch $BACKUP_DEST
      rm -f $BACKUP_LATEST
      ln -rs $BACKUP_DEST $BACKUP_LATEST
      echo "$(date -R) [$HOST] pruning snapshots older than $KEEP_DAYS days" >> $LOG
      find $BACKUP_HOST/ -mindepth 1 -maxdepth 1 -type d -mtime +$KEEP_DAYS -regextype posix-extended -regex '.*/[0-9]{8}_[0-9]{4}$' -exec rm -r "{}" \; >> $LOG 2>&1
    else
      echo "$(date -R) [$HOST] rsync failed" >> $LOG
      STATUS=1
      rmdir $BACKUP_DEST
    fi

    if [ ! -z "${POST_SCRIPT[$HOST]}" ]; then
      echo "$(date -R) [$HOST] running post-script ${POST_SCRIPT[$HOST]}" >> $LOG
      eval ${POST_SCRIPT[$HOST]} >> $LOG 2>&1
    fi

  else
    echo "$(date -R) [$HOST] pre-script failed, aborting" >> $LOG
    STATUS=1
  fi
  
done

test -f /var/tmp/.rsync_snap.status && echo $STATUS > /var/tmp/.rsync_snap.status
if [ $STATUS -eq 0 ]; then
  touch /var/tmp/.rsync_snap.last
fi

rm -f /tmp/.rsync_snap.lck

echo "$(date -R) *** script completed" >> $LOG

