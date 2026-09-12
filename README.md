# lanbat nixos

[![check](https://github.com/lanbat/nixos/actions/workflows/check.yml/badge.svg)](https://github.com/lanbat/nixos/actions/workflows/check.yml)

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

## How it fits together

Every server service is one file in `services/`. Besides configuring the service,
the file describes it under `lanbat.services.<name>`: its subdomain and port, who
authenticates users, whether its data lives on the encrypted workload layer, which
Pi drives it needs, its container account, secrets and dashboard entry. The
modules in `modules/wiring/` generate the Caddy vhosts, workload gating, NFS
dependencies, on-demand activators, accounts, agenix secrets and Homepage entries
from those descriptions, and evaluation fails on inconsistencies such as port
clashes. Importing a service file enables it.

```nix
lanbat.services.jellyfin = {
  subdomain = "media";
  port = 8096;
  apiClients = true;
  tier = "workload";
  state = [ "jellyfin" ];
  units = [ "jellyfin" ];
  nfs.drives = [ "a" ];
  account = { uid = 992; extraGroups = [ "media" ]; };
  dashboard = { group = "Media"; name = "Jellyfin"; description = "Media server"; };
};
```

## Repository structure

```
flake.nix                 hosts, deploy-rs nodes, checks, dev shell
local.nix.example         template for your settings (copy to local.nix, gitignored)
hosts/
  example-settings.nix    placeholder settings for the example hosts CI evaluates
  server/                 default.nix (imports, networking), disk.nix (disko layout), hardware.nix
  pi/                     default.nix, hardware.nix
services/                 one file per server service, each describing itself in lanbat.services
modules/
  core/                   settings, the service interface, base system, SSH, shared accounts
  wiring/                 vhosts, workload gating, NFS, on-demand, accounts, secrets, checks
  server/                 control LUKS layer and Tang gating, backups
  pi/                     Clevis unlock, storage, NFS exports, TV frontend, audio, voice, metrics
tests/                    assertion tests and the workload-gate VM test
pkgs/                     CA landing page, TV launcher, on-demand activator, helper scripts
secrets/                  agenix-encrypted secrets
docs/                     design, operations and deployment guides
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
| Zigbee2MQTT | `zigbee.<domain>` | Caddy fwd-auth |
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
| Bitmagnet | `bitmagnet.<domain>` | Starts on first request, stops after 3 days idle |

## Deploying

```bash
nix develop               # deploy (deploy-rs), agenix, nixos-anywhere

# Deploy from your workstation; rolls back if the new system breaks SSH
deploy path:.#server
deploy path:.#pi
```

The real `server` and `pi` configurations only exist when `local.nix` (copied from
`local.nix.example`) is present, and only a `path:` flake reference includes that
gitignored file. The server is installed with nixos-anywhere, which partitions its
disk from `hosts/server/disk.nix`. Hosts don't upgrade themselves: run
`nix flake update` and deploy. See
[docs/deployment-checklist.md](docs/deployment-checklist.md) for the full
step-by-step guide.

## Design principles

- **Server is the brain** — all compute, databases, SSO, and reverse proxy live on the server.
- **Pi is storage + TV** — encrypted drives, NFS export, Kodi, RetroArch.
- **Fail safe** — NFS-dependent services stop when the Pi is unreachable; they restart automatically when storage returns.
- **No Kubernetes** — systemd + Podman + NixOS modules are sufficient and far simpler.
- **Minimal containers** — NixOS native services are preferred where modules exist (Nextcloud, Jellyfin, HA, Samba, etc.). Containers are used where native packaging is impractical (Authentik, Immich, Frigate, etc.).
- **One place per service** — a service's vhost, tier, storage dependencies, account and secrets are declared in its own file and checked at evaluation.

## Contributing

Pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for how to check a
change locally and the conventions this repo follows, and [SECURITY.md](SECURITY.md)
for reporting vulnerabilities.

## License

[MIT](LICENSE)
