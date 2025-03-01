#!/bin/bash

LOCKFILE="/var/lock/`basename $0`"
LOCKFD=99
 
# PRIVATE
_lock()             { flock -$1 $LOCKFD; }
_no_more_locking()  { _lock u; _lock xn && rm -f $LOCKFILE; }
_prepare_locking()  { eval "exec $LOCKFD>\"$LOCKFILE\""; trap _no_more_locking EXIT; }
 
# ON START
_prepare_locking
 
# PUBLIC
exlock_now()        { _lock xn; }  # obtain an exclusive lock immediately or fail
exlock()            { _lock x; }   # obtain an exclusive lock
shlock()            { _lock s; }   # obtain a shared lock
unlock()            { _lock u; }   # drop a lock
 
# Simplest example is avoiding running multiple instances of script.
if ! exlock_now
then
  echo "Already running, aborting!" > /dev/stderr
  exit 1
fi

DATE="$(date +%H%M%S)"

rclone sync -v /home/wesley/frigate-docker/config frigate-backup:config &> "/home/wesley/backup-logs/backup-${DATE}.log"
rclone sync -v /mnt/frigate-storage frigate-backup:storage --exclude 'lost+found/**' &>> "/home/wesley/backup-logs/backup-${DATE}.log"

