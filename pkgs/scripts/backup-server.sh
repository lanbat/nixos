#!/usr/bin/env bash
# backup-server.sh
#
# Backup critical server-local state to Pi storage (Drive B, /backups).
#
# Backs up:
#   - PostgreSQL, both instances (pg_dumpall + per-database dumps):
#       always-on (port 5433): authentik, hass, grafana
#       workload  (port 5432): nextcloud, immich, bitmagnet — only while unlocked
#   - /var/lib/hass  (Home Assistant)
#   - /var/lib/caddy (Caddy config + CA keys)
#   - /var/lib/tang  (Tang private keys — CRITICAL)
#   - /var/lib/authentik
#   - /var/lib/nextcloud
#   - /var/lib/immich/profile
#   - /var/lib/frigate/config
#   - /var/lib/qbittorrent
#   - /var/lib/bitmagnet
#
# NOT backed up by this script:
#   - /srv/storage/a (Pi storage — backs up in its own right)
#   - /srv/storage/b (Pi storage)
#   - /var/cache     (regenerable)
#   - Container images (re-pull from registry)
#
# The backup destination is /srv/storage/b/backups/server on the server,
# which maps to /mnt/storage-b/backups/server on the Pi.
#
# Encrypt the backup archive if the destination is untrusted.
# For this homelab, the Pi storage is LUKS-encrypted so the backup
# is protected at rest without additional encryption.
#
# Run it as root. There is no timer for it yet (see modules/server/backups.nix).

set -euo pipefail

BACKUP_DIR=/srv/storage/b/backups/server
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DEST=$BACKUP_DIR/$TIMESTAMP

echo "[$TIMESTAMP] Starting server backup to $DEST..."

if [ ! -d "$BACKUP_DIR" ]; then
  echo "ERROR: backup destination $BACKUP_DIR not available (Pi NFS down?)." >&2
  exit 1
fi

install -d -m 0700 "$DEST"

# ---------------------------------------------------------------------------
# PostgreSQL
# ---------------------------------------------------------------------------
# dump_instance <label> <connection args> <databases...>
dump_instance() {
  local label=$1 conn=$2
  shift 2
  echo "  Dumping PostgreSQL ($label)..."
  install -d "$DEST/postgres-$label"
  # shellcheck disable=SC2086
  sudo -u postgres pg_dumpall $conn --clean --if-exists | \
    gzip > "$DEST/postgres-$label/pg_dumpall.sql.gz"
  for db in "$@"; do
    # shellcheck disable=SC2086
    sudo -u postgres pg_dump $conn --clean --if-exists "$db" | \
      gzip > "$DEST/postgres-$label/${db}.sql.gz"
  done
}

dump_instance always-on "-h /run/postgresql-always-on -p 5433" authentik hass grafana

if systemctl is-active --quiet postgresql.service; then
  dump_instance workload "-h /run/postgresql -p 5432" nextcloud immich bitmagnet
else
  echo "  Skipping the PostgreSQL workload instance: the workload layer is locked."
fi

# ---------------------------------------------------------------------------
# Service state
# ---------------------------------------------------------------------------
echo "  Backing up service state..."
rsync -a --delete /var/lib/hass/         "$DEST/hass/"
rsync -a --delete /var/lib/caddy/        "$DEST/caddy/"
rsync -a --delete /var/lib/tang/         "$DEST/tang/"
rsync -a --delete /var/lib/authentik/    "$DEST/authentik/"
rsync -a --delete /var/lib/nextcloud/    "$DEST/nextcloud/"
rsync -a --delete /var/lib/frigate/config/ "$DEST/frigate-config/"
rsync -a --delete /var/lib/qbittorrent/  "$DEST/qbittorrent/"
rsync -a --delete /var/lib/bitmagnet/    "$DEST/bitmagnet/"
rsync -a --delete /var/lib/immich/profile/ "$DEST/immich-profile/"

# Immich thumbs/encoded-video can be regenerated — skip them to save space.

# ---------------------------------------------------------------------------
# Rotate old backups — keep last 7 daily backups.
# ---------------------------------------------------------------------------
echo "  Rotating old backups (keeping 7)..."
ls -1d "$BACKUP_DIR"/[0-9]* 2>/dev/null | sort | head -n -7 | while read old; do
  echo "  Removing old backup: $old"
  rm -rf "$old"
done

echo "[$TIMESTAMP] Backup complete: $DEST"
