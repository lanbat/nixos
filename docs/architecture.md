# Architecture

Configuration is organized in three layers (see [extensibility.md](extensibility.md)):

| Layer | Purpose | Location |
|---|---|---|
| **Deployment profile** | Site/environment (domain, hosts, plugins) | `deployments/<profile>/deploy.nix` |
| **Role** | Host infrastructure bundle | `lib/roles/` (`server`, `storage-pi`, `voice-pi`) |
| **Plugin** | Optional features per host | `plugins/` + external flake inputs |

The flake builds one NixOS configuration per host in each active profile
(`homelab-server`, `homelab-pi-storage`, …). A single-profile `deploy.nix` without
a `profiles` wrapper uses unprefixed names (`server`, `pi-storage`).

## Overview

```
                         ┌──────────────────────────────────────────────────────────────┐
                         │                     SERVER                                   │
                         │                                                              │
                         │  LV root — host root (ext4, plain — available at boot)       │
                         │  ┌─────────────────────────────────────────────────────┐    │
                         │  │ SSH (22)  networking  firewall  admin tools          │    │
                         │  │ unlock-control / unlock-workload scripts             │    │
                         │  └────────────────────────┬────────────────────────────┘    │
                         │                           │ manual unlock (passphrase)       │
                         │  LV control — LUKS → /mnt/control                           │
                         │  ┌─────────────────────────────────────────────────────┐    │
                         │  │ Tang (7500) ──────────────────────────────────────┐ │    │
                         │  │  /mnt/control/tang → /var/lib/private/tang (bind) │ │    │
                         │  └───────────────────────────────────────────────────┼─┘    │
                         │                           │ manual unlock (passphrase)│      │
  LAN clients            │  LV workload — LUKS → /mnt/workload                  │      │
  ──────────────────────►│  ┌─────────────────────────────────────────────────┐ │      │
  (SMB: 445)             │  │ always-on + workload-online.target services     │ │      │
                         │  │  Caddy (443/80)         PostgreSQL (5432/5433)  │ │      │
                         │  │  Authentik (9000)        Redis (6379, 6380)     │ │      │
                         │  │  Home Assistant (8123)   Mosquitto (1883)       │ │      │
                         │  │  Nextcloud (8080)        Samba (445)            │ │      │
                         │  │  Vaultwarden (8222)      Grafana (3030)         │ │      │
                         │  │  InfluxDB (8086)         Music Assistant (8095) │ │      │
                         │  │  Snapserver (1704/1780)  Telegraf               │ │      │
                         │  │  Wyoming pipeline + satellite (10700)           │ │      │
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
                         │  TV sessions (tv-switch, controller hotkey)                  │
                         │    ├── Kodi                                                  │
                         │    └── EmulationStation (ES-DE) + RetroArch                  │
                         │  Snapclient ──► server:1704                                  │
                         │  Wyoming Satellite (10700) ◄── HA on server                  │
                         │  Telegraf → server:8086                                      │
                         │                                                              │
                         │  /dev/nvme0n1 — NVMe drive A                                │
                         │  ┌──────────────────────────────────────────────────────┐   │
                         │  │ LUKS2  →  XFS (pquota)   [locked until Tang replies] │   │
                         │  │  /mnt/storage-a/media/  (qBittorrent, Jellyfin)      │   │
                         │  │    movies, TV, music videos                          │   │
                         │  │  /mnt/storage-a/photos/      (Immich)                │   │
                         │  │  /mnt/storage-a/surveillance/(Frigate)               │   │
                         │  └──────────────────────────────────────────────────────┘   │
                         │                                                              │
                         │  /dev/nvme1n1 — NVMe drive B                                │
                         │  ┌──────────────────────────────────────────────────────┐   │
                         │  │ LUKS2  →  XFS (pquota)   [locked until Tang replies] │   │
                         │  │  /mnt/storage-b/media/  the rest of the media        │   │
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
- Voice assistant pipeline (Wyoming: wake word, STT, TTS; Home Assistant's
  conversation agent, backed by an external OpenAI-compatible LLM) and a voice
  satellite (microphone + internal speaker)
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
| Home Assistant | Caddy forward-auth (Authentik) + header auth + local break-glass | Companion apps use /auth/token; browser SSO via hass-auth-header |
| Nextcloud | OIDC (user_oidc app) + local admin | Native OIDC support |
| Immich | Caddy forward-auth (Authentik) + native OIDC | Bootstrap admin links to Authentik email; mobile apps use /api/* |
| Jellyfin | OIDC (plugin) or local | Native OIDC plugin available |
| Frigate | Caddy forward-auth (Authentik) | No native OIDC |
| qBittorrent | Caddy forward-auth + local app auth | No OIDC |
| Bitmagnet | Caddy forward-auth (Authentik) | No native OIDC |
| RomM | Caddy forward-auth (Authentik), then RomM accounts | OIDC not configured |
| SearXNG | None (intentional) | Public LAN search |
| Samba | Local smbpasswd (optionally Authentik LDAP) | SMB doesn't speak OIDC |
| MQTT | Local password file | IoT devices don't speak OIDC |
| Vaultwarden | Own account system + admin token | Bitwarden clients need direct API access; no forward auth |
| Grafana | OIDC (Authentik) + local admin | Native generic_oauth support |
| InfluxDB | Token auth (not exposed publicly) | Accessed by Grafana only; no browser UI needed on LAN |
| Syncthing | Caddy forward-auth (Authentik) | Sync clients use port 22000 directly, not Caddy |
| Music Assistant | Caddy forward-auth (Authentik) | No native OIDC; stream port (8097) not exposed on firewall |
| Snapcast | Caddy forward-auth (Authentik) | No native auth; streaming port (1704) is LAN-open |
| Wyoming satellites | No auth (Pi: firewall-restricted to server IP; server: localhost only) | Internal protocol; only HA connects |
| Wyoming pipeline (STT/TTS/wake word) | No auth (localhost only) | Never exposed outside server |
| Conversation LLM (`lanbat.haLlm`) | API key (agenix) | External OpenAI-compatible API; only HA calls it, outbound |

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
| `romm.<domain>` | RomM (on-demand) |
| `search.<domain>` | SearXNG |
| `ca.<domain>` | CA cert distribution |
| `vault.<domain>` | Vaultwarden password manager |
| `grafana.<domain>` | Grafana dashboards |
| `sync.<domain>` | Syncthing web UI |
| `music.<domain>` | Music Assistant web UI |
| `audio.<domain>` | Snapcast control UI (may merge with `music` when retired) |

DNS assumption: `*.<domain>` resolves to the server's IPv4 address.
This is configured in your router/DNS and is out of scope for this repo.

## On-demand services

Services with `lanbat.services.<name>.onDemand` start on the first HTTP request via
the activator proxy (`modules/wiring/on-demand.nix`) and stop after `idleMinutes` without
requests. Bitmagnet stops after 3 days idle, RomM after 30 minutes.

The activator is a lightweight Python proxy that:
1. Receives requests meant for Bitmagnet.
2. If Bitmagnet is not running: starts it, returns a loading page.
3. If Bitmagnet is running: transparently proxies the request.

## NFS dependency model

Services that read/write Pi storage set `lanbat.services.<name>.nfs.drives`.
`modules/wiring/nfs.nix` adds `bindsTo` and `after` dependencies on the NFS mount units.
If the mount disappears, the service is stopped. When the mount returns, the service restarts.

The mounts use soft NFS with a 30-second timeout,
meaning the kernel gives up on a stalled NFS call after ~90 seconds rather than
blocking forever.

## Tooling

Validate deployment files and query profile values from the flake:

```bash
nix run .#validate-deploy
nix run .#hosts
nix run .#deploy-query -- server-ip
```

See [extensibility.md](extensibility.md) for the full list of `deploy-query` keys.
