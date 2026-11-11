#!/usr/bin/env bash
set -euo pipefail

# cron jobs don't inherit the container env, so snapshot it for backup.sh to source
export -p > /etc/backup.env

# Safety net: if the container was killed mid-backup, nothing stays frozen
for s in $PAUSE_SERVICES; do
  for id in $(docker ps -q --filter "label=com.docker.compose.service=$s" --filter status=paused); do
    echo "Unpausing leftover paused container: $s"
    docker unpause "$id" || true
  done
done

SCHEDULE="${BACKUP_SCHEDULE:-0 3 * * *}"
echo "$SCHEDULE /usr/local/bin/backup.sh >/proc/1/fd/1 2>/proc/1/fd/2" > /etc/crontabs/root
echo "Backup scheduled: '$SCHEDULE' (TZ=${TZ:-UTC})"

if [ "${BACKUP_ON_START:-false}" = "true" ]; then
  ( /usr/local/bin/backup.sh || true ) &
fi

exec crond -f -l 8
