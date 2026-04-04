# Secure Layers Design

## Overview

The server uses a three-layer design that separates the host OS from sensitive
data. The Raspberry Pi uses the server's Tang service to auto-unlock its NVMe
drives after boot.

```
 ┌──────────────────────────────────────────────────────────────────────┐
 │  SERVER — three-layer storage                                        │
 │                                                                      │
 │  sda1  1 GiB   /boot     (EFI, vfat)          always available      │
 │  sda2 50 GiB   /         (ext4, no encryption) always available      │
 │  sda3 256 MiB  control   (LUKS2 → ext4)        locked at boot        │
 │  sda4 rest     workload  (LUKS2 → ext4)        locked at boot        │
 └──────────────────────────────────────────────────────────────────────┘
```

## Layer 1 — Host (always available)

- **Device**: `/dev/sda2`
- **Filesystem**: ext4, no encryption
- **Mount**: `/` (root)
- **Contains**: NixOS, SSH, networking, firewall, admin scripts, systemd units,
  always-on service data (PostgreSQL, Authentik, HA, Grafana, InfluxDB, Mosquitto,
  Frigate, Caddy TLS certs, container images)
- **Does NOT contain**: Tang keys, workload-gated service data (Nextcloud, Immich,
  Jellyfin, Vaultwarden, Syncthing, Samba, qBittorrent, Bitmagnet)

After a reboot, this layer is immediately accessible. SSH works. Admin tools
work. Nothing sensitive is exposed.

## Layer 2 — Control LUKS

- **Device**: `/dev/sda3`
- **Filesystem**: LUKS2 → ext4
- **Mount**: `/mnt/control` (manual, not at boot)
- **Unlocked by**: admin passphrase (`unlock-control`)
- **Contains**: `/mnt/control/tang/` — Tang key material only

A bind mount makes `/mnt/control/tang` available as `/var/lib/tang`.
Tang's socket unit (`tangd.socket`) is `WantedBy=control-online.target` and
will not start until that target is active.

## Layer 3 — Workload LUKS

- **Device**: `/dev/sda4`
- **Filesystem**: LUKS2 → ext4
- **Mount**: `/mnt/workload` (manual, not at boot)
- **Unlocked by**: admin passphrase (`unlock-workload`)
- **Contains**: workload-gated service data (Nextcloud, Immich, Jellyfin,
  Vaultwarden, Syncthing, Samba, qBittorrent, Bitmagnet)

Bind mounts overlay `/var/lib/<service>` paths with subdirectories of
`/mnt/workload`. The `workload-online.target` is activated once all bind mounts
are in place. Workload-gated services have `WantedBy=workload-online.target`
and `BindsTo=workload-online.target`. Always-on services are unaffected.

## Service tiers

Services are split into two tiers based on data sensitivity:

**Always-on (host root, start at boot, no unlock needed)**

| Service | Data path | Rationale |
|---|---|---|
| Caddy | `/var/lib/caddy` | Reverse proxy and TLS — must be up to serve all services, both tiers |
| PostgreSQL | `/var/lib/postgresql` | Shared database — needed by Authentik, Nextcloud, Bitmagnet |
| Authentik | `/var/lib/authentik` | Identity provider — SSO must be available for all auth flows |
| Home Assistant | `/var/lib/hass` | Automation and sensor history — availability over confidentiality |
| Grafana | `/var/lib/grafana` | Dashboards and metrics config — monitoring must be up at boot |
| InfluxDB | `/var/lib/influxdb2` | Time-series data — metrics collection starts immediately after boot |
| Mosquitto | `/var/lib/mosquitto` | MQTT broker — IoT devices reconnect at boot |
| Frigate | `/var/lib/frigate` | NVR event database — surveillance must not wait for unlock |
| Snapcast | — | Audio streaming — ephemeral, no persistent state |
| Wyoming pipeline | — | STT/TTS/wake word — model files managed by NixOS module |
| SearXNG | — | Search proxy — stateless |
| Telegraf | — | Metrics collector — stateless |
| Redis (Immich) | — | Ephemeral cache — no persistent state |
| Homepage | — | Dashboard — stateless, useful before workload is up |

**Workload-gated (LUKS-encrypted, start only after `unlock-workload`)**

```
/mnt/workload/
  nextcloud/      — Nextcloud home (config, apps, data)
  immich/         — Immich thumbnails, encoded video, profiles, DB
  jellyfin/       — Jellyfin library metadata
  vaultwarden/    — Vaultwarden vault database and attachments
  syncthing/      — Syncthing configuration and block index
  qbittorrent/    — qBittorrent config and session state
  bitmagnet/      — Bitmagnet torrent index
  samba/          — Samba configuration and state
```

Container images (`/var/lib/containers`) live on the unencrypted host root.
Images are public software; only the application data above is sensitive.

## Stub directories

Each `/var/lib/<service>` path for **workload-gated** services is a mode-`0000`
empty directory on host root (created by `secure-layers.nix`). When workload is
locked, these stubs are inaccessible — no service can read or write them. When
workload is unlocked, the bind mounts overlay the stubs with the real data.

This prevents accidental data leakage to host root if a service somehow starts
before workload is mounted (it would fail with a permissions error, which is the
correct and visible failure mode).

Always-on services manage their own `/var/lib/*` directories normally and have
no stubs — NixOS creates them with correct ownership at system activation.

## Tang gating

```
boot
 └── host root available
      └── [admin] unlock-control
           └── /mnt/control mounted
                └── /var/lib/tang bind-mounted
                     └── control-online.target activated
                          └── tangd.socket started
                               └── Tang serving keys
                                    └── Raspberry Pi Clevis unlock succeeds
                                         └── NVMe drives mounted on Pi
```

## Workload gating

```
boot
 └── host root available → SSH + always-on services start automatically
      │                    (Caddy, PostgreSQL, Authentik, HA, Grafana,
      │                     InfluxDB, Mosquitto, Frigate, Snapcast, Wyoming,
      │                     SearXNG, Telegraf)
      └── [admin] unlock-workload
           └── /mnt/workload mounted
                └── bind mounts activated (/var/lib/nextcloud, etc.)
                     └── workload-online.target activated
                          └── gated services start
                               (Nextcloud, Immich, Jellyfin, Vaultwarden,
                                Syncthing, Samba, qBittorrent, Bitmagnet)
```

## Raspberry Pi unlock model

The Pi boots from its SD card regardless of Tang availability. After network
is up, `storage-a-unlock.service` and `storage-b-unlock.service` attempt
Clevis/Tang unlock. If Tang is unreachable (server locked), the services fail
and retry every 5 minutes automatically. No manual intervention on the Pi
is needed — once the server is unlocked, the next retry succeeds.

## Known limitations

### Already-unlocked Pi volumes are not retroactively re-locked

Tang/Clevis gating controls **unlock-at-boot** behaviour only. It does **not**
retroactively re-lock NVMe volumes that are already mounted on a **running**
Raspberry Pi if the server is subsequently rebooted or the control LUKS layer
is locked.

**Concretely**: if the Pi's drives are unlocked and mounted, then you reboot or
lock the server, the Pi's drives **remain unlocked and mounted** until the Pi
itself is rebooted or an admin manually closes them.

**Operational implication**: to fully revoke Pi storage access, you must:
1. Stop NFS exports on the Pi (or stop relevant services on the server)
2. `umount /mnt/storage-a && cryptsetup luksClose storage-a` on the Pi
3. `umount /mnt/storage-b && cryptsetup luksClose storage-b` on the Pi
4. (Or simply reboot the Pi — the drives will stay locked until Tang is available)

This is a fundamental property of Tang/Clevis: it gates the unlock event, not
ongoing access to already-unlocked volumes.

### Host root is not encrypted

The host root (`/dev/sda2`) is plain ext4 with no LUKS encryption. This is
intentional: the server must be remotely administrable after reboot without
physical presence. An encrypted root would require someone to type the
passphrase at the physical console on every reboot.

Consequence: SSH host keys and the NixOS configuration on disk are visible
to anyone with physical access to the server disk. The secrets managed by
agenix (in the Nix store) are encrypted with age and are not readable
without the host SSH key — but the host SSH key itself is on unencrypted disk.

The confidentiality model relies on LUKS protecting sensitive data volumes,
not the host OS layer.

### Restic backup credentials are needed to restore

If you lose access to the restic repository passwords (stored as agenix secrets
on the server), you cannot access or restore from the encrypted restic
repositories. Keep restic passwords backed up separately (e.g. in a password
manager).
