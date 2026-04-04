# lanbat nixos

NixOS configuration for a two-machine homelab:

- **server** — main compute host, all services, reverse proxy, identity/SSO
- **pi** — encrypted storage appliance + TV/gaming frontend (Raspberry Pi 5)

## Quick links

- [Architecture](docs/architecture.md)
- [Secure layers design](docs/secure-layers.md)
- [Operational runbook](docs/runbook.md)
- [Deployment checklist](docs/deployment-checklist.md)
- [Storage layout](docs/storage-layout.md)
- [Failure modes](docs/failure-modes.md)
- [Security model](docs/security.md)
- [Backup strategy](docs/backup.md)
- [Operations guide](docs/operations.md)
- [Secrets setup](secrets/README.md)

## Repository structure

```
flake.nix                    entry point — two nixosConfigurations
local.nix.example            template for per-deployment settings (copy to local.nix, gitignored)
overlays/default.nix         exposes pkgs.unstable
modules/
  common/
    base.nix                 locale, nix settings, base packages
    users.nix                stable UIDs/GIDs across both machines
    ssh.nix                  hardened openssh config
  server/
    nfs-mounts.nix           /srv/storage/{a,b} NFS mount units
    nfs-dependent-service.nix  module: declare NFS dependencies for services
    on-demand.nix            on-demand service activator framework
  pi/
    clevis-unlock.nix        post-boot Clevis/Tang unlock (retries until Tang reachable)
    launcher.nix             TV launcher (X11 + openbox + Python/GTK)
hosts/
  server/
    default.nix              server host config — imports all services
    hardware-configuration.nix  TEMPLATE — replace with nixos-generate-config output
    services/
      tang.nix               Tang trust anchor (Pi LUKS unlock)
      caddy.nix              reverse proxy + internal CA
      authentik.nix          identity / SSO (OCI containers)
      home-assistant.nix     home automation (NixOS native)
      nextcloud.nix          file sync (NixOS native)
      immich.nix             photo library (OCI containers)
      jellyfin.nix           media server (NixOS native)
      vaultwarden.nix        password manager (NixOS native)
      grafana.nix            metrics dashboards (NixOS native)
      syncthing.nix          file synchronisation (NixOS native)
      snapcast.nix           multi-room audio server (NixOS native)
      wyoming.nix            voice assistant pipeline: STT/TTS/wake word (NixOS native)
      telegraf.nix           metrics agent → InfluxDB (NixOS native)
      influxdb.nix           time-series database (NixOS native)
      qbittorrent.nix        torrent client (OCI container)
      frigate.nix            NVR + cloud sync (OCI container)
      bitmagnet.nix          DHT search, on-demand (OCI container)
      searxng.nix            metasearch frontend (OCI container)
      homepage.nix           service dashboard (OCI container)
      samba.nix              SMB file server (NixOS native)
      mosquitto.nix          MQTT broker (NixOS native)
  pi/
    default.nix              Pi host config
    hardware-configuration.nix  TEMPLATE — replace with nixos-generate-config output
    services/
      storage.nix            LUKS mounts + directory init
      nfs-exports.nix        NFS server exports
      frontend.nix           Kodi/RetroArch hardware config
      snapclient.nix         Snapcast audio client (NixOS native)
      wyoming-satellite.nix  Wyoming voice satellite: mic + speaker (NixOS native)
      telegraf.nix           metrics agent → server InfluxDB (NixOS native)
pkgs/
  ca-landing-page/           CA trust distribution page (static HTML)
  launcher/                  TV launcher Python/GTK3 package
  on-demand-activator/       On-demand service proxy (Python)
  scripts/
    quota-setup.sh           XFS project quota initialization
    quota-report.sh          XFS quota usage report
    backup-server.sh         Nightly server → Pi backup
    trust-ca-linux.sh        CA install helper for Linux
    trust-ca-macos.sh        CA install helper for macOS
secrets/
  README.md                  How to create and manage agenix secrets
docs/
  architecture.md            System design and service map
  deployment-checklist.md    Step-by-step setup guide
  storage-layout.md          Drive layout, quotas, service storage plan
  failure-modes.md           What happens when things go wrong
  security.md                Security model and threat surface
  backup.md                  Backup strategy and restore procedures
  operations.md              Day-to-day management
```

## Services

Services run in two tiers. See [docs/secure-layers.md](docs/secure-layers.md) for the full design.

### Start at boot (no unlock needed)

| Service | URL | Auth |
|---|---|---|
| Homepage | `home.<domain>` | none |
| Authentik | `auth.<domain>` | local |
| Home Assistant | `ha.<domain>` | OIDC + local |
| Frigate | `nvr.<domain>` | Caddy fwd-auth |
| Grafana | `grafana.<domain>` | OIDC |
| SearXNG | `search.<domain>` | **none (intentional)** |
| CA page | `ca.<domain>` | none |
| Mosquitto | MQTT port 1883 | local password file |
| InfluxDB | internal only | token auth |
| Snapcast | `audio.<domain>` | Caddy fwd-auth |
| Wyoming voice assistant | no web UI (LAN-internal) | firewall-restricted |
| Telegraf | no web UI (writes to InfluxDB) | internal only |

### Workload-gated (require `unlock-workload` after reboot)

| Service | URL | Auth |
|---|---|---|
| Nextcloud | `cloud.<domain>` | OIDC |
| Immich | `photos.<domain>` | OIDC |
| Jellyfin | `media.<domain>` | OIDC / local |
| qBittorrent | `torrent.<domain>` | Caddy fwd-auth |
| Vaultwarden | `vault.<domain>` | own account system |
| Syncthing | `sync.<domain>` | Caddy fwd-auth |
| Samba | SMB port 445 | local smbpasswd |

### On-demand

| Service | URL | Notes |
|---|---|---|
| Bitmagnet | `bitmagnet.<domain>` | Starts on first request, stops after 30 min idle |

## Deploying

```bash
# Server (first time — from installer)
nixos-install --flake .#server --impure

# Server (updates)
nixos-rebuild switch --flake .#server --target-host admin@server --impure

# Pi
nixos-rebuild switch --flake .#pi --target-host admin@pi5 --impure
```

`--impure` is required so Nix reads your gitignored `local.nix` (copy from
`local.nix.example` and fill in your values before deploying).

See [docs/deployment-checklist.md](docs/deployment-checklist.md) for the full step-by-step guide.

## Design principles

- **Server is the brain** — all compute, databases, SSO, and reverse proxy live on the server.
- **Pi is storage + TV** — encrypted drives, NFS export, Kodi, RetroArch.
- **Fail safe** — NFS-dependent services stop when the Pi is unreachable; they restart automatically when storage returns.
- **No Kubernetes** — systemd + Podman + NixOS modules are sufficient and far simpler.
- **Minimal containers** — NixOS native services are preferred where modules exist (Nextcloud, Jellyfin, HA, Samba, etc.). Containers are used where native packaging is impractical (Authentik, Immich, Frigate, etc.).
- **Explicit dependencies** — every service that needs NFS declares it in `lanbat.nfsDependentServices`.
