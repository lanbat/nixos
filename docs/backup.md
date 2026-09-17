# Backup Strategy

## What needs to be backed up

### Critical (must back up — cannot be regenerated)

| Data | Location | Method |
|---|---|---|
| Tang private keys | `/var/lib/tang/` | `backup-server.sh` → Pi/b/backups |
| PostgreSQL databases (always-on and workload instances) | server | `pg_dumpall` of each instance via `backup-server.sh` |
| Authentik state | `/var/lib/authentik/` | `backup-server.sh` |
| Home Assistant config | `/var/lib/hass/` | `backup-server.sh` |
| Caddy root CA key | `secrets/caddy-ca-root-key.age` (agenix) + `secrets/caddy-ca-root.crt` (git) | git + agenix |
| Caddy intermediate/leaf state | `/var/lib/caddy/` | `backup-server.sh` (regenerates from root if lost) |
| agenix secrets | `secrets/*.age` | git repository |
| Frigate config | `/var/lib/frigate/config/` | `backup-server.sh` |
| Nextcloud config | `/var/lib/nextcloud/` | `backup-server.sh` (back up before any major upgrade — see `docs/runbook.md` § Nextcloud major version upgrade) |
| Vaultwarden data | `/var/lib/vaultwarden/` | `backup-server.sh` |
| InfluxDB data (metrics) | `/var/lib/influxdb2/` | `backup-server.sh` |
| Grafana state | `/var/lib/grafana/` | `backup-server.sh` |
| Syncthing config + index | `/var/lib/syncthing/` | `backup-server.sh` |

### Important (back up — slow to regenerate)

| Data | Location | Method |
|---|---|---|
| Immich originals | `/srv/storage/a/photos/` | Already on Pi LUKS storage |
| Immich DB | `/var/lib/immich/db/` | `backup-server.sh` |
| Kodi library | `/var/lib/kodi/.kodi/` | manual rsync |
| Nextcloud user data | `/srv/storage/b/nextcloud/` | Already on Pi LUKS storage |
| qBittorrent config | `/var/lib/qbittorrent/` | `backup-server.sh` |
| Music Assistant state | `/var/lib/music-assistant/` | `backup-server.sh` |

### Regenerable (do not need to back up)

| Data | Reason |
|---|---|
| Container images | Re-pull from registry |
| Jellyfin metadata/posters | Re-scan from media files |
| Immich thumbnails | Re-generated from originals |
| Transcode cache | Temporary by definition |
| Frigate ML models | Re-download from source |
| SearXNG config | Checked into this repo |
| Wyoming STT/TTS/wake word models | Re-downloaded on first service start |

## Backup schedule

### Server → Pi backup (nightly)

`backup-server.sh` writes to `/srv/storage/b/backups/server/` (Pi Drive B) and
keeps 7 daily backups. A nightly timer is defined in `modules/server/backups.nix`
(03:00, after `srv-storage-b.mount` is available). The script skips control- and
workload-layer paths when the matching LUKS layer is locked, so a backup taken
while locked is incomplete but never silently copies empty stubs as if they were
real data.

### Frigate clips → cloud (real-time)

`frigate-rclone-sync.service` (planned for `services/frigate.nix`)
watches the clips directory and uploads each clip as it closes.

This keeps a cloud copy of all detected-event clips.
Full 24h recordings stay on Pi storage only (they are too large for typical cloud plans).

Retention recommendation (indoor cameras, household):
- Local recordings: 7 days (set in `frigate.nix`)
- Event clips (local): 30 days (set in `frigate.nix`)
- Event clips (cloud): indefinite until you clean them up

### Pi storage (no backup by default)

The Pi drives are LUKS-encrypted. They are the "primary" bulk storage.
The server backup above puts a copy of the most critical parts (Immich DB, etc.) on Pi/b.

For full off-site backup of media/photos, set up a second rclone job:
```bash
# Example: sync Immich originals to Backblaze B2
rclone sync /srv/storage/a/photos/ b2:your-bucket/photos/ --fast-list
```

Add this as a weekly systemd timer.

## Restore procedure

### Worst case: server disk failure

1. Install new disk, boot NixOS installer.
2. Re-run the disk setup from `deployment-checklist.md`.
3. After install, restore from Pi backup:
   ```bash
   rsync -a /srv/storage/b/backups/server/LATEST/ /restore/
   # Restore PostgreSQL:
   sudo -u postgres psql < /restore/postgres/pg_dumpall.sql
   # Restore service state:
   rsync -a /restore/hass/ /var/lib/hass/
   rsync -a /restore/tang/ /var/lib/tang/
   # etc.
   ```
4. The Pi drives are intact and still encrypted to the same Tang key (which you restored).
5. Deploy from the workstation: `deploy path:.#homelab-server`

### Tang key loss

If Tang keys are lost and Clevis binding is broken:
1. Use the LUKS fallback passphrase to open the drives manually.
2. Re-install Tang (new keys auto-generated).
3. Re-bind the Pi drives: `clevis luks bind -d /dev/... tang '{"url":"http://server:7500"}'`
4. Test unlock.

This is why backing up `/var/lib/tang/` is **critical**.

### Pi drive failure

If a Pi drive dies:
- All data on that drive is lost (no RAID).
- Media can be re-added from original sources.
- Immich originals can be restored from cloud backup (if set up).
- Surveillance recordings are gone (acceptable for a homelab).
- Replace drive, re-format with LUKS + XFS, re-bind to Tang.

This is an intentional simplicity tradeoff. RAID adds complexity; two separate drives
with clear ownership is simpler to operate and understand.
