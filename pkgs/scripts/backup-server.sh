#!/usr/bin/env bash
# backup-server.sh
#
# Backup critical server-local state to Pi storage (Drive B, /backups).
#
# Backs up:
#   - PostgreSQL databases (pg_dumpall)
#   - /var/lib/hass  (Home Assistant)
#   - /var/lib/caddy (Caddy config + CA keys)
#   - /var/lib/tang  (Tang private keys — CRITICAL)
#   - /var/lib/authentik
#   - /var/lib/nextcloud
#   - /var/lib/immich (metadata, NOT originals — those are already on Pi)
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
# Run via systemd timer: see the systemd service in hosts/server/default.nix
# (add a timer that calls this script nightly).

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
echo "  Dumping PostgreSQL..."
install -d "$DEST/postgres"
sudo -u postgres pg_dumpall --clean --if-exists | \
  gzip > "$DEST/postgres/pg_dumpall.sql.gz"

# Per-database dumps as well.
for db in authentik nextcloud bitmagnet; do
  sudo -u postgres pg_dump --clean --if-exists "$db" | \
    gzip > "$DEST/postgres/${db}.sql.gz"
done

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
rsync -a --delete /var/lib/immich/db/    "$DEST/immich-db/"   # Postgres data dir
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
