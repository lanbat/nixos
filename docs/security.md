# Security Model

## Encryption at rest

### Server — three-layer design

The server uses a three-layer design. See `docs/secure-layers.md` for full detail.

- **`/dev/sda2` (host root)** — plain ext4, **not encrypted**. Contains NixOS, SSH,
  networking, admin tools, and always-on service data (PostgreSQL, Authentik, HA,
  Grafana, InfluxDB, Mosquitto, Frigate, Caddy TLS certs). Always available after boot.
  This is intentional: the server must be remotely administrable after reboot without
  physical presence. An encrypted root would require console access for every reboot.

- **`/dev/sda3` (control LUKS)** — LUKS2-encrypted. Contains only Tang key material.
  Unlocked manually by admin after each reboot (`unlock-control`). Until unlocked, Tang
  is unavailable and the Pi cannot auto-unlock its NVMe drives.

- **`/dev/sda4` (workload LUKS)** — LUKS2-encrypted. Contains workload-gated service
  data: Nextcloud, Immich, Jellyfin, Vaultwarden, Syncthing, Samba, qBittorrent,
  Bitmagnet. Unlocked manually by admin after each reboot (`unlock-workload`).

**Threat model**: if the server is stolen while both LUKS layers are locked, the
attacker gets SSH access to an empty host but cannot reach Tang (Pi drives stay locked)
and cannot access workload data. Host-root data (PostgreSQL, HA history, etc.) is
visible, so it is treated as lower-sensitivity data.

### Pi
- Both NVMe drives are LUKS2-encrypted.
- After boot, post-boot services (`storage-a-unlock`, `storage-b-unlock`) contact Tang
  and unlock the drives via Clevis. They retry every 5 minutes until Tang is reachable.
- If the Pi is stolen without the server, drives cannot be decrypted (Tang is unreachable).
- If both server and Pi are stolen while LUKS layers are locked, drives cannot be
  decrypted — Tang keys are on the server's control LUKS, which is locked.
- Fallback LUKS passphrase exists for recovery (set during initial formatting).
- **Back up the Tang key directory** (`/mnt/control/tang/`) — if lost, the LUKS slots
  bound to Tang cannot be opened without the fallback passphrase.

## Network trust

### LAN trust model
- The internal network is treated as **partially trusted** — not zero-trust.
- All web services are HTTPS via Caddy's internal CA.
- Services that handle sensitive data (Authentik, Nextcloud, Immich) use OIDC.
- Services that are admin-only (Frigate, qBittorrent, Bitmagnet) are behind Authentik forward auth.
- SearXNG is intentionally unauthenticated (it's a search proxy, not a private service).

### Firewall
- Server allows: 22 (SSH), 80 (redirect to HTTPS), 443 (HTTPS), 7500 (Tang), 2049 (NFS — Pi only), 1883 (MQTT — LAN only).
- NFS and MQTT are restricted by IP in `extraCommands`.
- Pi allows: 22, 2049 (server only).
- All other inbound traffic is dropped.

### IPv6 exposure
- Caddy binds on IPv6 (`[::]`) for the frontend only.
- Backend services all bind on `127.0.0.1` (IPv4 localhost only).
- No IPv6 is enabled on backend containers.
- **Risk**: if your router advertises a global IPv6 prefix, Caddy's port 443 becomes accessible on that IPv6 address. This is intentional for remote access but means the LAN trust assumption weakens for IPv6.
- To disable IPv6 on Caddy: add `bind 0.0.0.0` to all virtual hosts in caddy.nix.
- **Action required**: review your router's IPv6 firewall rules to block port 443 from the internet if you don't want public access.

## Authentik / SSO risks

- Authentik is the single point of failure for most service auth.
- If Authentik is compromised, all OIDC-integrated services are compromised.
- Mitigation: Authentik runs only on the server (always-on tier, starts at boot).
- All services retain break-glass local admin accounts (Nextcloud admin, HA admin, etc.) — these do not go through Authentik.
- Authentik's own PostgreSQL password is managed via agenix (encrypted at rest in git).

## Home Assistant and Zigbee

- HA runs as a NixOS service with access to the Zigbee USB dongle via udev rules.
- The `ha` group owns the serial device — only the HA service and root can access it.
- HA is not exposed on IPv6 by default (Caddy proxies it on v4 internally).
- HA retains local admin — do not disable it.
- Zigbee devices communicate on 2.4 GHz RF; this is a separate attack surface (ZHA has strong security defaults).

## Frigate / cameras

- Camera RTSP streams should use authentication (set in frigate.yml).
- Frigate UI is behind Authentik forward auth.
- Frigate binds on `127.0.0.1:5000` only — not accessible except through Caddy.
- Recordings are stored on encrypted Pi storage.
- Cloud-synced clips use rclone with credentials in an age-encrypted file.
- **Privacy consideration**: indoor cameras. Frigate does motion/object detection locally — nothing is sent to cloud except the clips you configure to sync.

## Reverse proxy isolation

- All services are exposed exclusively through Caddy. No service binds on a public port directly.
- Backend services bind on `127.0.0.1` or use Unix sockets.
- Container services use `--network host` to reach PostgreSQL/Redis on localhost, but do not bind public ports (port mapping is to `127.0.0.1` explicitly).
- The one exception: qBittorrent uses bridge networking with port mapped to `127.0.0.1:8090`.

## Secrets

- All secrets are age-encrypted via agenix.
- Secrets are decrypted by the host using its SSH host key.
- If the server disk is encrypted and the SSH host key is on that disk, secrets are protected at rest.
- The git repository stores only encrypted `.age` files — safe to push to GitHub.
- **Do not** store plaintext passwords or API keys anywhere in this repo.

## Least privilege

- Service users (jellyfin, immich, frigate, qbt) run as UIDs 991-994 with no sudo.
- Each service has its own user/group; they share the `media` group only for storage access.
- Containers run as non-root where possible (linuxserver.io images use PUID/PGID).
- The `admin` human user has `wheel` but is not used for day-to-day service management.

## Break-glass accounts

Every service has a local admin account that does not go through Authentik:
- Nextcloud: `admin` user with password from agenix.
- Home Assistant: local admin configured at first setup.
- qBittorrent: local web UI password (set at first run, stored in `/var/lib/qbittorrent`).
- Authentik: initial admin set at `/if/flow/initial-setup/`.

These accounts should be strong passwords stored in a password manager, not in this repo.
