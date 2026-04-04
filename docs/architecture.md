# Architecture

## Overview

```
                         ┌──────────────────────────────────────────────────────────────┐
                         │                     SERVER                                   │
                         │                                                              │
                         │  /dev/sda2 — host root (ext4, plain — available at boot)     │
                         │  ┌─────────────────────────────────────────────────────┐    │
                         │  │ SSH (22)  networking  firewall  admin tools          │    │
                         │  │ unlock-control / unlock-workload scripts             │    │
                         │  └────────────────────────┬────────────────────────────┘    │
                         │                           │ manual unlock (passphrase)       │
                         │  /dev/sda3 — control LUKS → /mnt/control                    │
                         │  ┌─────────────────────────────────────────────────────┐    │
                         │  │ Tang (7500) ──────────────────────────────────────┐ │    │
                         │  │  /mnt/control/tang/ ←→ /var/lib/tang (bind mount) │ │    │
                         │  └───────────────────────────────────────────────────┼─┘    │
                         │                           │ manual unlock (passphrase)│      │
  LAN clients            │  /dev/sda4 — workload LUKS → /mnt/workload           │      │
  ──────────────────────►│  ┌─────────────────────────────────────────────────┐ │      │
  (SMB: 445)             │  │ workload-online.target (all services)           │ │      │
                         │  │  Caddy (443/80)         PostgreSQL (5432)       │ │      │
                         │  │  Authentik (9000)        Redis (6379, 6380)     │ │      │
                         │  │  Home Assistant (8123)   Mosquitto (1883)       │ │      │
                         │  │  Nextcloud (8080)        Samba (445)            │ │      │
                         │  │  Vaultwarden (8222)      Grafana (3030)         │ │      │
                         │  │  InfluxDB (8086)         Snapserver (1704/1780) │ │      │
                         │  │  Wyoming pipeline        Telegraf               │ │      │
                         │  │  Jellyfin / Frigate / Immich / qBittorrent      │ │      │
                         │  │  Bitmagnet / Syncthing / Homepage / SearXNG     │ │      │
                         │  └──────────────────────────┬──────────────────────┘ │      │
                         │                             │ NFS (2049)              │      │
                         └─────────────────────────────┼─────────────────────────┼──────┘
                                                       │                         │
                                                       │   CLEVIS/TANG unlock    │
                                                       │ (Tang TCP 7500) ◄───────┘
                                                       │ retries every 5 min
                                                       │ until Tang reachable
                         ┌─────────────────────────────▼────────────────────────────────┐
                         │                   RASPBERRY PI                               │
                         │                                                              │
                         │  SD card: NixOS OS (boots independently of Tang)            │
                         │                                                              │
                         │  NFS server  ──►  exports /mnt/storage-{a,b}               │
                         │  TV Launcher (openbox)                                       │
                         │    ├── Kodi                                                  │
                         │    └── RetroArch                                             │
                         │  Snapclient ──► server:1704                                  │
                         │  Wyoming Satellite (10700) ◄── HA on server                  │
                         │  Telegraf → server:8086                                      │
                         │                                                              │
                         │  /dev/nvme0n1 — NVMe drive A                                │
                         │  ┌──────────────────────────────────────────────────────┐   │
                         │  │ LUKS2  →  XFS (pquota)   [locked until Tang replies] │   │
                         │  │  /mnt/storage-a/media/       (Jellyfin)              │   │
                         │  │  /mnt/storage-a/downloads/   (qBittorrent)           │   │
                         │  │  /mnt/storage-a/photos/      (Immich)                │   │
                         │  │  /mnt/storage-a/surveillance/(Frigate)               │   │
                         │  └──────────────────────────────────────────────────────┘   │
                         │                                                              │
                         │  /dev/nvme1n1 — NVMe drive B                                │
                         │  ┌──────────────────────────────────────────────────────┐   │
                         │  │ LUKS2  →  XFS (pquota)   [locked until Tang replies] │   │
                         │  │  /mnt/storage-b/nextcloud/   (Nextcloud)             │   │
                         │  │  /mnt/storage-b/users/       (SMB homes)             │   │
                         │  │  /mnt/storage-b/shared/      (SMB shared)            │   │
                         │  │  /mnt/storage-b/backups/     (backup target)         │   │
                         │  └──────────────────────────────────────────────────────┘   │
                         └──────────────────────────────────────────────────────────────┘
```

## Service responsibilities

**Server is responsible for:**
- All compute-heavy work (Immich ML, Jellyfin transcoding, Frigate detection)
- All databases (PostgreSQL, SQLite)
- All caches and indexes
- Reverse proxy and TLS
- Identity and SSO
- MQTT broker
- Tang trust anchor
- Voice assistant pipeline (Wyoming: STT, TTS, wake word)
- Metrics storage (InfluxDB) and dashboards (Grafana)
- Metrics collection from both machines (Telegraf)

**Pi is responsible for:**
- Encrypted bulk storage
- NFS export
- TV/gaming frontend
- Voice hardware endpoint (Wyoming satellite: microphone + speaker)
- Metrics collection (Telegraf → server InfluxDB)

## Auth matrix

| Service | Auth method | Why |
|---|---|---|
| Authentik | local only | It IS the identity provider |
| Homepage | none | LAN landing page |
| Home Assistant | OIDC (Authentik) + local break-glass | Native OIDC support |
| Nextcloud | OIDC (user_oidc app) + local admin | Native OIDC support |
| Immich | OIDC (native) + local admin | Native OIDC support |
| Jellyfin | OIDC (plugin) or local | Native OIDC plugin available |
| Frigate | Caddy forward-auth (Authentik) | No native OIDC |
| qBittorrent | Caddy forward-auth + local app auth | No OIDC |
| Bitmagnet | Caddy forward-auth (Authentik) | No native OIDC |
| SearXNG | None (intentional) | Public LAN search |
| Samba | Local smbpasswd (optionally Authentik LDAP) | SMB doesn't speak OIDC |
| MQTT | Local password file | IoT devices don't speak OIDC |
| Vaultwarden | Own account system + admin token | Bitwarden clients need direct API access; no forward auth |
| Grafana | OIDC (Authentik) + local admin | Native generic_oauth support |
| InfluxDB | Token auth (not exposed publicly) | Accessed by Grafana only; no browser UI needed on LAN |
| Syncthing | Caddy forward-auth (Authentik) | Sync clients use port 22000 directly, not Caddy |
| Snapcast | Caddy forward-auth (Authentik) | No native auth; streaming port (1704) is LAN-open |
| Wyoming satellite | No auth (firewall-restricted to server IP) | Internal protocol; only HA connects |
| Wyoming pipeline (STT/TTS/wake word) | No auth (localhost only) | Never exposed outside server |

## Hostname map

| Hostname | Service |
|---|---|
| `home.<domain>` | Homepage dashboard |
| `auth.<domain>` | Authentik IdP |
| `cloud.<domain>` | Nextcloud |
| `photos.<domain>` | Immich |
| `media.<domain>` | Jellyfin |
| `ha.<domain>` | Home Assistant |
| `nvr.<domain>` | Frigate NVR |
| `torrent.<domain>` | qBittorrent |
| `bitmagnet.<domain>` | Bitmagnet (on-demand) |
| `search.<domain>` | SearXNG |
| `ca.<domain>` | CA cert distribution |
| `vault.<domain>` | Vaultwarden password manager |
| `grafana.<domain>` | Grafana dashboards |
| `sync.<domain>` | Syncthing web UI |
| `audio.<domain>` | Snapcast control UI |

DNS assumption: `*.<domain>` resolves to the server's IPv4 address.
This is configured in your router/DNS and is out of scope for this repo.

## On-demand services

Bitmagnet is started on first HTTP request via the activator proxy
(`modules/server/on-demand.nix`). It stops after 30 minutes of inactivity.

The activator is a lightweight Python proxy that:
1. Receives requests meant for Bitmagnet.
2. If Bitmagnet is not running: starts it, returns a loading page.
3. If Bitmagnet is running: transparently proxies the request.

## NFS dependency model

Services that read/write Pi storage are declared in `lanbat.nfsDependentServices`.
This adds `bindsTo` and `after` systemd dependencies on the NFS mount unit.
If the mount disappears, the service is stopped. When the mount returns, the service restarts.

The `modules/server/nfs-mounts.nix` module uses soft NFS with a 30-second timeout,
meaning the kernel gives up on a stalled NFS call after ~90 seconds rather than
blocking forever.
