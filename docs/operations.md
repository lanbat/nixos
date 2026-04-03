# Operations Guide

## Deploying changes

`--impure` is required so Nix reads `local.nix` from disk (it is gitignored and
therefore outside the pure flake source). See `local.nix.example` for setup.

```bash
# Deploy to server
nixos-rebuild switch --flake .#server --target-host admin@server --impure

# Deploy to Pi
nixos-rebuild switch --flake .#pi --target-host admin@pi5 --impure

# Build locally first to check for errors
nix build .#nixosConfigurations.server.config.system.build.toplevel --impure
nix build .#nixosConfigurations.pi.config.system.build.toplevel --impure
```

## Unattended upgrades

Both machines run `nixos-upgrade.service` nightly (server ~04:00, Pi ~04:30).
It pulls the latest commit from `/etc/nixos` and runs `nixos-rebuild switch`.

```bash
# Check the last upgrade on the server
systemctl status nixos-upgrade.service
journalctl -u nixos-upgrade.service -n 50

# Check the git pull step
journalctl -u nixos-upgrade-pull.service -n 20

# On the Pi
ssh admin@pi5 journalctl -u nixos-upgrade.service -n 50
```

**Server:** upgrades apply immediately but the machine is **not rebooted** —
a new kernel only takes effect after the next manual reboot.  Check whether a
reboot is pending:
```bash
[ "$(readlink /run/booted-system)" = "$(readlink /nix/var/nix/profiles/system)" ] \
  && echo "up to date" || echo "reboot pending"
```

**Pi:** upgrades apply immediately and the machine **reboots automatically**
(between 04:00–06:00) if a reboot is needed.  Clevis/Tang handles LUKS unlock
automatically.  NFS-dependent services on the server will briefly pause and
auto-restart as usual.

### Disabling auto-upgrade temporarily

```bash
# Prevent the next scheduled run (survives until the timer fires again)
sudo systemctl stop nixos-upgrade.timer

# Re-enable
sudo systemctl start nixos-upgrade.timer
```

### Pinning a specific commit

If an upgrade breaks something, pin the repo to a known-good commit:

```bash
ssh admin@server
sudo git -C /etc/nixos checkout <good-commit-hash>
# Auto-upgrade will now rebuild from this commit until you move HEAD forward.
```

## Checking service health

```bash
# Overall status
systemctl status caddy authentik-server authentik-worker
systemctl status podman-jellyfin podman-qbittorrent podman-frigate
systemctl status podman-immich-server podman-homepage podman-searxng
systemctl status postgresql redis-authentik redis-immich
systemctl status home-assistant mosquitto samba-smbd tang
systemctl status vaultwarden grafana influxdb2

# NFS mount status
systemctl status srv-storage-a.automount srv-storage-b.automount
mountpoint /srv/storage/a /srv/storage/b

# On Pi: storage status
lsblk -f
systemctl status nfs-server mnt-storage-a.mount mnt-storage-b.mount
```

## Updating container images

```bash
# Pull latest images
podman pull ghcr.io/goauthentik/server:2024.12.2
podman pull ghcr.io/immich-app/immich-server:release

# Rebuild to apply new images
nixos-rebuild switch --flake .#server

# Or pull and restart manually:
podman pull IMAGE:TAG
systemctl restart podman-IMAGE
```

**Best practice:** pin container image tags to specific versions in the service
`.nix` files. Update the tag deliberately, not with `:latest`.

## Managing Samba users

Samba uses local password storage (smbpasswd). Users must be Linux users first.

```bash
# Add a new user (must have a Linux account in users.nix first)
sudo smbpasswd -a alice        # sets Samba password
sudo smbpasswd -e alice        # enable if disabled

# Remove a user
sudo smbpasswd -x alice

# List Samba users
sudo pdbedit -L

# Create a user home dir on Pi storage
sudo mkdir -p /srv/storage/b/users/alice
sudo chown alice:media /srv/storage/b/users/alice
sudo chmod 0700 /srv/storage/b/users/alice
```

## Tang key management

```bash
# Check Tang is serving keys
curl http://localhost:7500/adv | jq

# Generate a new key (keep old key for transition period)
sudo tangd-keygen /var/lib/tang

# After rotation: re-bind each Pi LUKS volume
# (Run on Pi)
clevis luks regen -d /dev/disk/by-id/DRIVE_A_ID
clevis luks regen -d /dev/disk/by-id/DRIVE_B_ID

# Remove old key (after Pi is confirmed working with new key)
# List keys:
ls /var/lib/tang/
# The .jwk files starting with . are deprecated; delete them:
sudo rm /var/lib/tang/.OLDKEYID.jwk
```

## Checking quotas

```bash
# SSH to Pi
ssh admin@pi5

# Project quotas (per-directory)
sudo xfs_quota -x -c "report -pb -h" /mnt/storage-a
sudo xfs_quota -x -c "report -pb -h" /mnt/storage-b

# User quotas
sudo xfs_quota -x -c "report -ub -h" /mnt/storage-a

# Set a project limit (example: cap surveillance at 500 GB)
sudo xfs_quota -x -c "limit -p bsoft=500g bhard=550g surveillance" /mnt/storage-a
```

## Accessing Bitmagnet (on-demand)

Bitmagnet starts automatically when you visit `https://bitmagnet.<domain>`.
You'll see a loading page for ~30 seconds on first access.
It stops 30 minutes after the last request.

To start/stop manually:
```bash
sudo systemctl start podman-bitmagnet
sudo systemctl stop podman-bitmagnet
```

## Viewing logs

```bash
# Service logs
journalctl -u caddy -f
journalctl -u home-assistant -f
journalctl -u podman-frigate -f

# All container logs together
journalctl -t podman -f

# NFS mount events
journalctl -u srv-storage-a.mount -f

# System boot log (useful for Clevis unlock debugging)
journalctl -b 0 | grep -i clevis
```

## Backup status

```bash
# Check last backup
ls -lht /srv/storage/b/backups/server/ | head -5
```

> Note: automated backup via systemd timer is not yet implemented in the config.
> Run backups manually with rsync/pg_dumpall for now — see `docs/backup.md`.

## Rebuilding Immich thumbnails

If thumbnails are lost (e.g. after restoring the server):
1. Log into Immich web UI.
2. Administration → Jobs → Generate Thumbnails → Run All.
This regenerates thumbnails from originals (on Pi storage).

## Home Assistant

```bash
# Restart HA (e.g. after config change)
sudo systemctl restart home-assistant

# HA logs
journalctl -u home-assistant -n 200

# HA config check
sudo -u hass hass --script check_config -c /var/lib/hass
```

## Nextcloud

```bash
# Run Nextcloud OCC commands
sudo -u nextcloud /run/current-system/sw/bin/nextcloud-occ <command>

# Scan for new files in external storage
sudo -u nextcloud nextcloud-occ files:scan --all

# Check Nextcloud status
sudo -u nextcloud nextcloud-occ status
```

## Grafana

```bash
# Restart Grafana (e.g. after updating grafana-env.age)
sudo systemctl restart grafana

# Check provisioned datasources loaded correctly
journalctl -u grafana -n 50
```

## InfluxDB

```bash
# Check InfluxDB is running and healthy
systemctl status influxdb2
curl -s http://127.0.0.1:8086/health

# Query via CLI (requires the operator token)
influx query 'from(bucket:"metrics") |> range(start: -1h)' \
  --host http://127.0.0.1:8086 \
  --token "$(cat /run/agenix/influxdb-admin-token)"
```

## Authentik

```bash
# Check server and worker are running
systemctl status podman-authentik-server podman-authentik-worker

# Logs
journalctl -u podman-authentik-server -f
journalctl -u podman-authentik-worker -f

# Restart (e.g. after updating authentik-env.age)
systemctl restart podman-authentik-server podman-authentik-worker
```

### Upgrading Authentik

Authentik is pinned to a specific version in `hosts/server/services/authentik.nix`
(`authentikVersion`). To upgrade:

1. Check the [Authentik release notes](https://docs.goauthentik.io/docs/releases) —
   Authentik requires sequential upgrades (do not skip major versions).
2. Update `authentikVersion` in `authentik.nix`.
3. Rebuild: `nixos-rebuild switch --flake .#server --target-host admin@server --impure`

### Adding a user

Go to **Directory → Users → Create**. Fill in username, name, email.
Set a password via **Actions → Update Password**, or send an invitation email
(requires email backend configuration in Authentik).

To restrict access to specific applications, use **Groups** and bind them to
providers via the provider's **Policy/Group Bindings** tab.

### Resetting a user password

**Directory → Users → \<user\> → Actions → Update Password**

Or via the self-service recovery flow:
`https://auth.<domain>/if/flow/default-recovery-flow/`

### Adding a new forward-auth service

When adding a new Caddy vhost that uses `authentikFwdAuth`:

1. Create a **Proxy Provider** (Forward auth, single application) with the service's external host.
2. Create an **Application** linked to that provider.
3. Edit the **embedded-outpost** and add the new application.

No NixOS rebuild required — Caddy already routes all `authentikFwdAuth` vhosts through
the embedded outpost.

## Vaultwarden

```bash
# Restart Vaultwarden (e.g. after updating vaultwarden-env.age)
sudo systemctl restart vaultwarden

# Logs
journalctl -u vaultwarden -f
```
