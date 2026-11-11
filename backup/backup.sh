#!/usr/bin/env bash
# Homelab backup: DB dumps -> pause apps -> restic to local repo -> copy to offsite -> prune
set -uo pipefail
# shellcheck disable=SC1091
source /etc/backup.env

HOMELAB_ROOT="${HOMELAB_ROOT:-/opt/homelab}"
DUMP_DIR="/tmp/homelab_db_dumps"
FAILED=0
PAUSED=()

# Never run two backups at once
exec 9>/tmp/backup.lock
flock -n 9 || { echo "Another backup is already running, exiting."; exit 1; }

# Required: LOCAL_REPOSITORY, RESTIC_PASSWORD. Optional: OFFSITE_REPOSITORY
: "${LOCAL_REPOSITORY:?LOCAL_REPOSITORY not set}"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD not set}"
export RESTIC_FROM_PASSWORD="$RESTIC_PASSWORD"   # same password for both repos
HOST_TAG="homelab"                                # fixed host name so snapshots chain (container hostname changes)
read -ra EXTRA <<< "${BACKUP_EXTRA_PATHS:-}"      # extra paths to include (e.g. the folder with docker-compose.yml and .env)

cid() { docker ps -q --filter "label=com.docker.compose.service=$1" | head -n1; }

cleanup() {
  # ALWAYS runs, even on failure: never leave containers frozen
  for id in "${PAUSED[@]:-}"; do
    [ -n "$id" ] && docker unpause "$id" >/dev/null 2>&1 || true
  done
  rm -rf "$DUMP_DIR"
}
trap cleanup EXIT

dump_pg() { # <compose service> <db user> <name>
  local id; id="$(cid "$1")"
  if [ -z "$id" ]; then echo "  !! $1 is not running, skipping"; FAILED=1; return; fi
  echo " -> Dumping $3 ($1)"
  if ! docker exec "$id" pg_dumpall -U "$2" | gzip > "$DUMP_DIR/$3.sql.gz"; then
    echo "  !! dump of $3 failed"; rm -f "$DUMP_DIR/$3.sql.gz"; FAILED=1
  fi
}

ensure_repo() { # <repo> [extra init args]
  local repo="$1"; shift
  restic -r "$repo" cat config >/dev/null 2>&1 || { echo " -> Initialising repo $repo"; restic -r "$repo" init "$@"; }
}

echo "=== Backup started $(date -Is) ==="

echo "[1/5] Checking repositories..."
ensure_repo "$LOCAL_REPOSITORY" || exit 1
if [ -n "${OFFSITE_REPOSITORY:-}" ]; then
  # --copy-chunker-params makes 'restic copy' deduplicate properly between repos
  ensure_repo "$OFFSITE_REPOSITORY" --from-repo "$LOCAL_REPOSITORY" --copy-chunker-params || FAILED=1
fi

echo "[2/5] Dumping databases..."
rm -rf "$DUMP_DIR"; mkdir -p "$DUMP_DIR"
dump_pg immich-db       "${DB_USERNAME:-postgres}"             immich
dump_pg affine-db       "${AFFINE_DB_USERNAME:-postgres}"      affine
dump_pg miniflux-db     "${MINIFLUX_DB_USER:-miniflux}"        miniflux
dump_pg paperless-db    "${PAPERLESS_POSTGRES_USER:-paperless}" paperless

echo "[3/5] Pausing app containers..."
for s in $PAUSE_SERVICES; do
  id="$(cid "$s")"
  [ -n "$id" ] && docker pause "$id" >/dev/null 2>&1 && PAUSED+=("$id") && echo " -> paused $s"
done

echo "[4/5] Restic snapshot -> $LOCAL_REPOSITORY"
# Raw Postgres data dirs are excluded on purpose: the SQL dumps cover them,
# and a file-level copy of a live Postgres is not reliably restorable.
restic -r "$LOCAL_REPOSITORY" backup \
  --host "$HOST_TAG" --tag homelab \
  --exclude "$HOMELAB_ROOT/media" \
  --exclude "$HOMELAB_ROOT/immich/upload/thumbs" \
  --exclude "$HOMELAB_ROOT/immich/upload/encoded-video" \
  --exclude "$HOMELAB_ROOT/immich/db" \
  --exclude "$HOMELAB_ROOT/affine/db" \
  --exclude "$HOMELAB_ROOT/miniflux/data" \
  --exclude "$HOMELAB_ROOT/paperless/postgres" \
  --exclude "$HOMELAB_ROOT/paperless/redis" \
  --exclude "$HOMELAB_ROOT/paperless/consume" \
  --exclude "$HOMELAB_ROOT/paperless/export" \
  --exclude "$HOMELAB_ROOT/tdarr/logs" \
  --exclude "$HOMELAB_ROOT/stirling/logs" \
  "$HOMELAB_ROOT" "$DUMP_DIR" "${EXTRA[@]}" || { echo "  !! restic backup failed"; FAILED=1; }

echo " -> Unpausing containers..."
for id in "${PAUSED[@]:-}"; do
  [ -n "$id" ] && docker unpause "$id" >/dev/null 2>&1
done
PAUSED=()

echo "[5/5] Offsite copy + retention..."
if [ -n "${OFFSITE_REPOSITORY:-}" ]; then
  restic -r "$OFFSITE_REPOSITORY" copy --from-repo "$LOCAL_REPOSITORY" || { echo "  !! offsite copy failed"; FAILED=1; }
fi

RETENTION=(--keep-daily "${KEEP_DAILY:-7}" --keep-weekly "${KEEP_WEEKLY:-4}" --keep-monthly "${KEEP_MONTHLY:-12}" --host "$HOST_TAG" --prune)
restic -r "$LOCAL_REPOSITORY" forget "${RETENTION[@]}" || FAILED=1
if [ -n "${OFFSITE_REPOSITORY:-}" ]; then
  restic -r "$OFFSITE_REPOSITORY" forget "${RETENTION[@]}" || FAILED=1
fi

if [ "$FAILED" -ne 0 ]; then
  echo "=== Backup finished WITH ERRORS $(date -Is) ==="
  exit 1
fi
echo "=== Backup completed successfully $(date -Is) ==="
