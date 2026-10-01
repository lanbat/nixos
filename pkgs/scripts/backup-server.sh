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
#   - /var/lib/tang  (Tang private keys — CRITICAL; control layer only)
#   - /var/lib/authentik
#   - /var/lib/nextcloud
#   - /var/lib/immich/profile
#   - /var/lib/frigate/config
#   - /var/lib/music-assistant
#   - /var/lib/qbittorrent
#   - /var/lib/bitmagnet
#   - /var/lib/audiobookshelf/config (accounts and listening progress)
#   - /var/lib/vaultwarden (the database through SQLite's online backup)
#   - Syncthing's config and identity (/var/lib/syncthing/.config/syncthing,
#     without the index, which Syncthing rebuilds)
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
# Run it as root. A nightly timer is defined in modules/server/backups.nix.

set -euo pipefail

BACKUP_DIR=/srv/storage/b/backups/server
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DEST=$BACKUP_DIR/$TIMESTAMP

control_online() { systemctl is-active --quiet control-online.target; }
workload_online() { systemctl is-active --quiet workload-online.target; }

echo "[$TIMESTAMP] Starting server backup to $DEST..."

if [ ! -d "$BACKUP_DIR" ]; then
  echo "ERROR: backup destination $BACKUP_DIR not available (Pi NFS down?)." >&2
  exit 1
fi

install -d -m 0700 "$DEST"

# copy_state <dir> <name> [rsync options...]: mirror a service's state into
# $DEST/<name>. A directory this host does not have is skipped, not fatal: a
# profile need not run every service, and one failed copy must not cost the
# rest of the backup.
copy_state() {
  local src=$1 name=$2
  shift 2
  if [ -d "$src" ]; then
    rsync -a --delete "$@" "$src/" "$DEST/$name/"
  else
    echo "  Skipping $src: not on this host."
  fi
}

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
  runuser -u postgres -- pg_dumpall $conn --clean --if-exists | \
    gzip > "$DEST/postgres-$label/pg_dumpall.sql.gz"
  for db in "$@"; do
    # shellcheck disable=SC2086
    runuser -u postgres -- pg_dump $conn --clean --if-exists "$db" | \
      gzip > "$DEST/postgres-$label/${db}.sql.gz"
  done
}

dump_instance always-on "-h /run/postgresql-always-on -p 5433" authentik hass grafana

if workload_online; then
  dump_instance workload "-h /run/postgresql -p 5432" nextcloud immich bitmagnet
else
  echo "  Skipping the PostgreSQL workload instance: the workload layer is locked."
fi

# ---------------------------------------------------------------------------
# Service state
# ---------------------------------------------------------------------------
echo "  Backing up always-on service state..."
# Frigate's config is rendered from the profile (lanbat.services.frigate.settings).
copy_state /var/lib/hass            hass
copy_state /var/lib/caddy           caddy
copy_state /var/lib/authentik       authentik
copy_state /var/lib/music-assistant music-assistant

if control_online; then
  echo "  Backing up control-layer state..."
  copy_state /var/lib/tang tang
else
  echo "  Skipping /var/lib/tang: the control layer is locked."
fi

if workload_online; then
  echo "  Backing up workload-layer state..."
  copy_state /var/lib/nextcloud             nextcloud
  copy_state /var/lib/qbittorrent           qbittorrent
  copy_state /var/lib/bitmagnet             bitmagnet
  copy_state /var/lib/immich/profile        immich-profile
  copy_state /var/lib/audiobookshelf/config audiobookshelf-config

  # The vault: attachments, sends and keys by rsync, and the live database
  # through SQLite's online backup, so a write during the copy can't tear it.
  if [ -d /var/lib/vaultwarden ]; then
    copy_state /var/lib/vaultwarden vaultwarden --exclude 'db.sqlite3*' --exclude 'icon_cache/'
    sqlite3 /var/lib/vaultwarden/db.sqlite3 ".backup '$DEST/vaultwarden/db.sqlite3'"
  fi

  # Syncthing's device identity (cert.pem, key.pem) and folder config; the
  # index is rebuilt by rescanning.
  copy_state /var/lib/syncthing/.config/syncthing syncthing --exclude 'index-*'
else
  echo "  Skipping workload service state: the workload layer is locked."
fi

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
