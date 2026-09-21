# lanbat nixos

[![check](https://github.com/lanbat/nixos/actions/workflows/check.yml/badge.svg)](https://github.com/lanbat/nixos/actions/workflows/check.yml)

Extensible NixOS configuration for homelab deployments. Each **deployment profile**
is a site (home lab, cabin, staging, …) with its own domain, hosts, and plugins.
Within a profile, hosts take **roles** (server, storage-pi, voice-pi) and enable
**plugins** (services, TV frontend, voice satellite, or external flake inputs).

See [docs/extensibility.md](docs/extensibility.md) for multi-site and multi-machine
patterns, and flake apps for validation (`nix run .#validate-deploy`) and deploy
queries (`nix run .#hosts`, `nix run .#deploy-query -- server-ip`).

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
- [Android device provisioning](docs/android-devices.md)
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
flake.nix                 dynamic hosts from deployment profiles, deploy-rs, checks
deploy.nix.example        root manifest listing active profiles (copy to deploy.nix)
deployments/
  example/deploy.nix      CI example profile
  homelab/deploy.nix.example   template for one site
lib/                      host builder, roles, plugin loader
plugins/                  built-in plugins (services, tv, voice)
services/                 one file per server service
modules/                  core, wiring, server, pi infrastructure
hosts/server/             hardware.nix, disk.nix (disko layout)
hosts/pi/                 hardware.nix (Raspberry Pi 5)
tests/                    assertion tests and VM tests
docs/                     architecture, extensibility, plugins, migration
```

## First run

Going from a fresh clone to a running site. The full step-by-step — disk layout
(disko), secrets, and post-install — is in
[docs/deployment-checklist.md](docs/deployment-checklist.md).

1. **Enter the dev shell** — it provides `deploy` (deploy-rs), `agenix` and
   `nixos-anywhere`:
   ```bash
   nix develop
   ```
2. **Create the local deploy files** from the checked-in templates. The real files
   are gitignored, so your domain, IPs and plugins are never committed:
   ```bash
   cp deploy.nix.example deploy.nix
   cp deployments/homelab/deploy.nix.example deployments/homelab/deploy.nix
   ```
   Then edit `deployments/homelab/deploy.nix` to set your domain, host IPs and the
   plugins each host enables (see [docs/extensibility.md](docs/extensibility.md)).
3. **Encrypt your secrets** — see [secrets/README.md](secrets/README.md).
4. **Deploy** each host:
   ```bash
   deploy path:.#homelab-server
   deploy path:.#homelab-pi-storage
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
| Zigbee2MQTT | `zigbee.<domain>` | Caddy fwd-auth (MQTT bridge to HA) |
| CA page | `ca.<domain>` | none |
| Mosquitto | MQTT port 1883 | local password file |
| InfluxDB | internal only | token auth |
| Music Assistant | `music.<domain>` | Caddy fwd-auth |
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
| Bitmagnet | `bitmagnet.<domain>` | Starts on first request, stops after 3 days idle (DHT index needs uptime) |
| RomM | `romm.<domain>` | Starts on first request, stops after 30 min idle |

> **External plugin example:** the reference homelab adds *parking-guard* — Frigate-LPR
> parking enforcement that alerts on unauthorised plates — as an external flake plugin,
> wired in the gitignored `deploy.nix` (not one of the built-in services above). See
> [docs/extensibility.md](docs/extensibility.md#external-plugins).

## Deploying

```bash
nix develop               # deploy (deploy-rs), agenix, nixos-anywhere

# (First time? see "First run" above.) Deploy with a path: reference:
deploy path:.#homelab-server
deploy path:.#homelab-pi-storage
```

Host names are `<profile>-<host-key>` (e.g. `homelab-server`). A single-profile
setup that inlines `{ deployment, hosts }` in `deploy.nix` without a `profiles`
wrapper uses unprefixed names (`server`, `pi-storage`).

Configurations only exist when `deploy.nix` is present (gitignored). CI evaluates
the checked-in `deployments/example` profile as `example-server` and
`example-pi-storage`. See [docs/deployment-checklist.md](docs/deployment-checklist.md).

## Design principles

- **Server is the brain** — all compute, databases, SSO, and reverse proxy live on the server.
- **Pi is storage + TV** — encrypted drives, NFS export, Kodi and EmulationStation.
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
