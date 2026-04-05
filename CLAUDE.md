# CLAUDE.md — Lanbat Homelab NixOS

This is a two-machine NixOS homelab:
- **server** — x86_64, main compute + services
- **pi** — Raspberry Pi 5 (aarch64), encrypted bulk storage + TV frontend

Read `docs/architecture.md` and `docs/secure-layers.md` for the full picture before making changes.

---

## Adding a new service

Follow this checklist every time:

1. **Create** `hosts/server/services/<name>.nix`
2. **Import** it in `hosts/server/default.nix`
3. **Add a Caddy vhost** in `hosts/server/services/caddy.nix`
4. **Decide the service tier** (see "Service tiers" section below):
   - **Always-on**: service starts at boot, data lives on host root — do nothing extra
   - **Workload-gated**: add to `bindMounts` and `gatedServices` in `modules/server/workload-gate.nix`,
     and add a mode-0000 stub in `modules/server/secure-layers.nix`
5. **Declare secrets** in both:
   - `secrets/secrets.nix` — agenix recipients
   - `hosts/server/default.nix` → `age.secrets` block
6. **Update docs**:
   - `docs/architecture.md` — auth matrix + hostname map + ASCII diagram if always-on
   - `docs/secure-layers.md` — add to the correct tier table
   - `docs/backup.md` — if the service has state that must be backed up
   - `docs/failure-modes.md` — add to "stays up" or "pauses" list
   - `docs/storage-layout.md` — add to the correct state section and service table
   - `docs/deployment-checklist.md` — if post-install steps are needed
   - `secrets/README.md` — add new secrets to the inventory table

---

## Patterns to follow

### Local deployment settings

Deployment-specific values (IPs, keys, timezone, etc.) live in `local.nix`,
which is gitignored. Never hardcode them in tracked files. The template is
`local.nix.example`. When adding a new deployment-time value:

1. Add a `lib.mkOption` to `modules/common/settings.nix` with a `CHANGE_ME` default.
2. Add the corresponding entry to `local.nix.example`.
3. Reference it as `config.lanbat.<option>` in service files.

### Centralized settings
Never hardcode network values, timezone, or the admin SSH key. All live in
`modules/common/settings.nix` and are set once per deployment:

| Option | Used for |
|---|---|
| `config.lanbat.domain` | All service hostnames |
| `config.lanbat.rootDomain` | Parent DNS zone |
| `config.lanbat.serverIp` | Server IPv4 address |
| `config.lanbat.piIp` | Pi IPv4 address |
| `config.lanbat.gatewayIp` | Default gateway |
| `config.lanbat.lanSubnet` | LAN-only firewall rules |
| `config.lanbat.serverHostname` | Server hostname |
| `config.lanbat.piHostname` | NFS mount target / Pi hostname |
| `config.lanbat.nfsIdmapdDomain` | NFSv4 ID mapping domain (must match on both hosts) |
| `config.lanbat.timezone` | System timezone + service TZ env vars |
| `config.lanbat.phoneRegion` | Phone number formatting (Nextcloud) |
| `config.lanbat.haLatitude` | Home Assistant home latitude |
| `config.lanbat.haLongitude` | Home Assistant home longitude |
| `config.lanbat.haElevation` | Home Assistant home elevation (metres) |
| `config.lanbat.serverControlLuksUuid` | UUID of server control LUKS (`/dev/sda3`) |
| `config.lanbat.serverWorkloadLuksUuid` | UUID of server workload LUKS (`/dev/sda4`) |
| `config.lanbat.piStorageDriveA` | Pi NVMe drive A by-id filename |
| `config.lanbat.piStorageDriveB` | Pi NVMe drive B by-id filename |
| `config.lanbat.adminSshKey` | Admin SSH public key (both hosts) |
| `config.lanbat.zigbeeDongle` | Zigbee dongle `/dev/serial/by-id/` path |
| `config.lanbat.zigbeeVendorId` | Zigbee dongle USB vendor ID |
| `config.lanbat.zigbeeProductId` | Zigbee dongle USB product ID |

For the domain specifically, the common pattern in service files is:
```nix
let domain = config.lanbat.domain; in
```

### Service tiers

Services run in one of two tiers. Assign the tier based on data sensitivity and
availability requirements:

**Always-on** (start at boot, data on unencrypted host root):
- Service starts automatically without any LUKS unlock
- Data directory (`/var/lib/<name>`) is created by NixOS normally
- Do NOT add a stub or bind mount for this service
- Current members: Caddy, PostgreSQL, Authentik, Home Assistant, Grafana, InfluxDB,
  Mosquitto, Frigate, Snapcast, Wyoming pipeline, SearXNG, Telegraf, Redis (Immich),
  Homepage

**Workload-gated** (start only after `unlock-workload`, data on encrypted LUKS):
- Service is gated on `workload-online.target`
- Data lives in `/mnt/workload/<name>/` and is bind-mounted to `/var/lib/<name>`
- Requires three additions:
  1. `modules/server/workload-gate.nix` → add to `bindMounts` and `gatedServices`
  2. `modules/server/secure-layers.nix` → add a mode-0000 stub:
     `"d /var/lib/<name> 0000 root root -"`
- Current members: Nextcloud, Immich, Jellyfin, Vaultwarden, Syncthing, Samba,
  qBittorrent, Bitmagnet

When in doubt, prefer **always-on** for monitoring/automation/infrastructure services
and **workload-gated** for personal data vaults (passwords, photos, documents, media).

### Prefer NixOS-native services over containers
Use `services.<name>` when a good NixOS module exists.
Use `virtualisation.oci-containers` only when necessary (e.g. Immich needs pgvecto.rs).

### NFS-dependent services
Any service that reads/writes Pi storage (`/srv/storage/a` or `/srv/storage/b`)
must declare its dependency:
```nix
lanbat.nfsDependentServices."<systemd-unit-name>" = [ "a" ];  # or [ "b" ] or [ "a" "b" ]
```
This wires `bindsTo` + `after` on the NFS mount unit so the service stops cleanly
when Pi storage disappears and restarts when it comes back.
The systemd unit name for a container is `podman-<container-name>`.
For NixOS-native services, use the actual unit name (e.g. `samba-smbd`, not `samba`).

### Secrets
- Inject secrets at runtime via `environmentFile` or `age.secrets.<name>.path` —
  never inline plaintext in Nix expressions.
- Only declare a secret in `age.secrets` if a service actually consumes
  `config.age.secrets.<name>.path`. Orphaned declarations cause build failures
  if the `.age` file doesn't exist.
- For environment variable injection into NixOS-native services, set:
  ```nix
  systemd.services.<name>.serviceConfig.EnvironmentFiles = [
    config.age.secrets.<name>-env.path
  ];
  ```
  Then reference values with Grafana-style `$__env{VAR}` or standard `${VAR}`
  depending on the service.

### Ports
Check for conflicts before assigning a port. Current allocations:
| Port | Service |
|------|---------|
| 1704 | Snapcast streaming |
| 1705 | Snapcast control |
| 1780 | Snapcast web UI |
| 1883 | Mosquitto MQTT |
| 2049 | NFS |
| 2283 | Immich |
| 3000 | Homepage |
| 3012 | Vaultwarden WebSocket |
| 3030 | Grafana |
| 3332 | Bitmagnet on-demand activator |
| 5000 | Frigate |
| 5432 | PostgreSQL (NixOS shared instance) |
| 5433 | PostgreSQL (Immich containerized instance) |
| 6379 | Redis (Authentik) |
| 6380 | Redis (Immich) |
| 7500 | Tang |
| 8080 | Nextcloud |
| 8086 | InfluxDB (Pi Telegraf writes here; firewall-restricted to Pi IP) |
| 8090 | qBittorrent |
| 8096 | Jellyfin |
| 8123 | Home Assistant |
| 8222 | Vaultwarden |
| 8554 | Frigate RTSP |
| 8888 | SearXNG |
| 9000 | Authentik |
| 8384 | Syncthing web UI |
| 9999 | Caddy on-demand TLS check |
| 10300 | Wyoming openwakeword (localhost only) |
| 10301 | Wyoming faster-whisper (localhost only) |
| 10302 | Wyoming piper (localhost only) |
| 10700 | Wyoming satellite on Pi (server→Pi) |
| 22000 | Syncthing sync (TCP + UDP) |

### Caddy auth
- Services with **native OIDC** (Nextcloud, Immich, Grafana): no forward auth in Caddy.
- Services with **no auth** (Frigate, qBittorrent, Bitmagnet): use `authentikFwdAuth`.
- Services with **their own account system** (Vaultwarden, Jellyfin): no forward auth —
  clients need direct API access.
- Never put Authentik forward auth in front of Vaultwarden or any service whose
  mobile/desktop clients make direct API calls.

### systemd.tmpfiles.rules
Never declare `systemd.tmpfiles.rules` twice in the same `.nix` file — Nix will
throw a duplicate attribute error. Merge all rules into a single list.

---

## Things to avoid

- **Hardcoding the domain** — use `config.lanbat.domain`
- **Declaring unused secrets** — only declare what a service actually uses
- **Using `linux_rpi4` kernel packages on the Pi 5** — use `boot.kernelModules`
  for kernel module loading instead of package references
- **Targeting the wrong samba unit** — the file-serving unit is `samba-smbd`,
  not `samba`
- **Duplicate `systemd.tmpfiles.rules` blocks** in the same file
- **Committing plaintext secrets** — all secrets go in `.age` files only
- **Adding a mode-0000 stub for an always-on service** — stubs are only for workload-gated
  services; always-on services manage their own `/var/lib/*` directories
- **Forgetting the bind mount or stub when adding a workload-gated service** — both
  `bindMounts` in `workload-gate.nix` and the stub in `secure-layers.nix` are required
