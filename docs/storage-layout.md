# Storage Layout

## Physical layout

```
Raspberry Pi 5
├── Boot media (microSD / USB)
│   └── NixOS system
│
├── Drive A  /dev/disk/by-id/DRIVE_A  →  LUKS  →  /dev/mapper/storage-a  →  XFS  →  /mnt/storage-a
│   ├── /mnt/storage-a/media/              ← Jellyfin libraries (movies, TV, music)
│   │   ├── movies/
│   │   ├── tv/
│   │   └── music/
│   ├── /mnt/storage-a/downloads/          ← qBittorrent output
│   │   ├── admin/                         ← per-user download dirs
│   │   └── ...
│   ├── /mnt/storage-a/photos/             ← Immich originals / uploads
│   └── /mnt/storage-a/surveillance/       ← Frigate recordings
│       ├── clips/
│       └── exports/
│
└── Drive B  /dev/disk/by-id/DRIVE_B  →  LUKS  →  /dev/mapper/storage-b  →  XFS  →  /mnt/storage-b
    ├── /mnt/storage-b/nextcloud/          ← Nextcloud external storage
    ├── /mnt/storage-b/users/              ← per-user SMB home dirs
    │   ├── admin/
    │   └── ...
    ├── /mnt/storage-b/shared/             ← shared SMB space
    └── /mnt/storage-b/backups/            ← server backup target
        └── server/
            └── YYYYMMDD-HHMMSS/

Main Server
└── /srv/storage/  (NFS mounts from Pi)
    ├── a/   →  NFS  →  pi5:/mnt/storage-a
    └── b/   →  NFS  →  pi5:/mnt/storage-b
```

## Server-local state — host root (always available, unencrypted)

These paths live on `/dev/sda2` and are accessible at boot without any unlock.

```
/var/lib/
├── caddy/             Caddy TLS state, internal CA keys
├── hass/              Home Assistant config + SQLite DB
├── authentik/         Authentik media, certs
├── postgresql/        PostgreSQL data directory
├── frigate/
│   ├── config/        frigate.yml
│   └── db/            Frigate SQLite event DB
├── grafana/           Grafana dashboards, users, alert state
├── influxdb2/         InfluxDB data + WAL (BACK THIS UP)
├── mosquitto/         Mosquitto broker state
├── homepage/          Homepage config (stateless, managed in repo)
└── containers/        Podman container image storage

/var/lib/tang/         ← bind mount from /mnt/control/tang (control LUKS)
                         Tang key pairs (BACK THIS UP — only available when
                         control is unlocked)
```

## Server-local state — workload LUKS (available after `unlock-workload`)

These paths are mode-0000 stubs on host root. When workload is unlocked they
are overlaid by bind mounts from `/mnt/workload/`.

```
/mnt/workload/
├── nextcloud/         Nextcloud app + config (bulk data is on Pi)
├── immich/
│   ├── db/            Immich PostgreSQL data (pgvecto.rs)
│   ├── thumbs/        Generated thumbnails
│   ├── encoded-video/ Re-encoded video previews
│   ├── profile/       User profile photos
│   └── model-cache/   CLIP / face detection ML models (~4 GB)
├── jellyfin/          Jellyfin metadata and configuration
├── qbittorrent/       qBittorrent config + fast-resume data
├── bitmagnet/         Bitmagnet config
├── vaultwarden/       Vaultwarden SQLite DB + attachments (BACK THIS UP)
├── syncthing/         Syncthing config + SQLite index (BACK THIS UP)
│                      (actual synced files are on Pi/b/syncthing)
└── samba/             Samba configuration and state

/var/cache/
├── jellyfin/          Jellyfin transcodes + metadata cache (safe to delete)
└── frigate/           Frigate frame buffer (tmpfs equivalent)
```

## Which service reads/writes where

| Service | Config | Database | Bulk content / originals |
|---|---|---|---|
| Caddy | server-local | — | — |
| Authentik | server-local | server-local (PostgreSQL) | — |
| Home Assistant | server-local | server-local (SQLite) | — |
| Nextcloud | server-local | server-local (PostgreSQL) | Pi/b (external storage) |
| Immich | server-local | server-local (container PG) | Pi/a/photos |
| Jellyfin | server-local | server-local | Pi/a/media |
| qBittorrent | server-local | — | Pi/a/downloads |
| Frigate | server-local | server-local (SQLite) | Pi/a/surveillance |
| Bitmagnet | server-local | server-local (PostgreSQL) | — |
| SearXNG | server-local | — | — |
| Homepage | server-local | — | — |
| Samba | (via nss) | — | Pi/a + Pi/b |
| MQTT | server-local | — | — |
| Vaultwarden | server-local | server-local (SQLite) | — |
| Grafana | server-local | server-local (SQLite) | — |
| InfluxDB | server-local | server-local | — |
| Syncthing | server-local | server-local (SQLite index) | Pi/b/syncthing |
| Snapcast | — | — | — (stateless; audio piped at runtime) |
| Wyoming (server) | — | — | — (models re-downloaded on first start) |
| Wyoming satellite (Pi) | — | — | — (stateless) |
| Telegraf (server + Pi) | — | → InfluxDB | — |

## XFS project quotas

Project quotas enforce per-directory space limits on the Pi drives.

### Setup

Run `quota-setup.sh` on the Pi after first format (see docs/deployment-checklist.md).

### Project ID assignments

| Project name | ID | Path | Drive | Suggested limit |
|---|---|---|---|---|
| media | 100 | /mnt/storage-a/media | A | no limit (fill the drive) |
| downloads | 101 | /mnt/storage-a/downloads | A | 1 TB soft, 1.1 TB hard |
| photos | 102 | /mnt/storage-a/photos | A | no limit |
| surveillance | 103 | /mnt/storage-a/surveillance | A | 500 GB soft, 550 GB hard |
| nextcloud | 200 | /mnt/storage-b/nextcloud | B | 500 GB soft, 550 GB hard |
| users | 201 | /mnt/storage-b/users | B | no limit |
| shared | 202 | /mnt/storage-b/shared | B | 200 GB soft, 220 GB hard |
| backups | 203 | /mnt/storage-b/backups | B | 300 GB soft, 350 GB hard |

### Per-user quotas

XFS also supports user and group quotas alongside project quotas (pquota enables all three).
To set a per-user limit (e.g. cap user "alice" at 100 GB on Drive B):

```bash
sudo xfs_quota -x -c "limit bsoft=100g bhard=110g alice" /mnt/storage-b
```

User IDs must be consistent between the Pi and server (see modules/common/users.nix).

### Reporting

```bash
# Project quotas
sudo xfs_quota -x -c "report -pb -h" /mnt/storage-a
sudo xfs_quota -x -c "report -pb -h" /mnt/storage-b

# User quotas
sudo xfs_quota -x -c "report -ub -h" /mnt/storage-a
```

## Drive allocation rationale

**Drive A** holds performance-sensitive or large-reads-required content:
- Media (Jellyfin sequential reads)
- Downloads (qBittorrent writes)
- Photos (Immich uploads and reads)
- Surveillance (Frigate continuous writes)

This drive sees the most write I/O (downloads + surveillance).
If it fills, remove old recordings first.

**Drive B** holds user data and backups:
- Nextcloud external storage (mixed read/write)
- SMB user homes (mixed)
- Shared space
- Server backups (periodic writes)

This drive is more backup/sync oriented.

## mergerfs (future option)

If you eventually want a single merged view of both drives:

```nix
# Add to Pi storage config
fileSystems."/mnt/storage-merged" = {
  device  = "/mnt/storage-a:/mnt/storage-b";
  fsType  = "fuse.mergerfs";
  options = [ "defaults" "allow_other" "minfreespace=20G" "fsname=storage-merged" ];
  depends = [ "/mnt/storage-a" "/mnt/storage-b" ];
};
```

This is not in the base config — keep drives separate for operational clarity.
Add mergerfs only if you have a specific reason (e.g. a single large Plex library
that spans both drives).
