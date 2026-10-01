# Operations Guide

Day-to-day work on a running site: deploying, updating, checking health, and per-service
tasks. For locking and unlocking the encrypted layers, restores and other procedures
after a reboot or failure, see the [runbook](runbook.md).

## Tools

`nix develop` in the repository opens a shell with `deploy` (deploy-rs), `agenix` and
`nixos-anywhere`. `deploy` only exists inside that shell.

## Deploying changes

Deploy from your workstation with a `path:` flake reference. `deploy.nix` and profile
files under `deployments/` are gitignored and only a `path:` reference includes them.

```bash
nix develop                                        # once per terminal
deploy --skip-checks path:.#homelab-server
deploy --skip-checks path:.#homelab-pi-storage     # builds on the Pi itself

# Build without deploying, to check for errors
nix build path:.#nixosConfigurations.homelab-server.config.system.build.toplevel
```

**Why `--skip-checks`:** before deploying, deploy-rs runs `nix flake check`, which
*builds* every check, including the Pi's `aarch64-linux` ones. An `x86_64` workstation
can't build those ("platform mismatch"), and the check needs 15–19 GB of memory in one
process. CI runs every check on each pull request, one process per check and the
`aarch64` ones on an arm runner, so skipping them locally loses nothing. To check a
change before deploying, build the host as above, or one check with
`nix build .#checks.x86_64-linux.<name>`.

Host names are `<profile>-<host-key>`. A single-profile setup that inlines
`{ deployment, hosts }` in `deploy.nix` without a `profiles` wrapper uses unprefixed
names (`server`, `pi-storage`).

deploy-rs activates the new system, then confirms it over a fresh SSH connection. If
activation fails or the host becomes unreachable, it rolls back to the previous
generation on its own.

A deploy doesn't start workload-gated services while the workload layer is locked.

### Rolling back by hand

```bash
ssh admin@server sudo nixos-rebuild switch --rollback
```

## Updating

Hosts change only when you deploy from your workstation with deploy-rs. No host
rebuilds itself: there is no `nixos-upgrade` timer and no copy of this repository
on the hosts. (Earlier versions rebuilt nightly from a clone under `/etc/nixos`,
which silently reverted any deploy the clone lacked, including changes to the
gitignored `deploy.nix`; see [Moving off the nightly rebuild](#moving-off-the-nightly-rebuild).)

To update nixpkgs and the other inputs:

```bash
nix flake update
nix build path:.#nixosConfigurations.homelab-server.config.system.build.toplevel
git commit -m "flake.lock: update" flake.lock
deploy --skip-checks path:.#homelab-server
deploy --skip-checks path:.#homelab-pi-storage
```

**Server:** a deploy activates the new system but never reboots the machine; a new
kernel only takes effect after the next manual reboot. Check whether a reboot is pending:

```bash
[ "$(readlink /run/booted-system/kernel)" = "$(readlink /run/current-system/kernel)" ] \
  && echo "up to date" || echo "reboot pending"
```

After a server reboot, unlock both layers (see `docs/runbook.md`).

**Pi:** the same applies. Run the check above on the Pi and reboot it when convenient
(`ssh admin@pi5 sudo systemctl reboot`); Clevis/Tang unlocks its drives, and
NFS-dependent services on the server briefly pause and restart as usual.

### Unattended updates

If you want updates without running `deploy` by hand, schedule the deploy itself
rather than a rebuild on the host, so the scheduled run deploys exactly what you
would have deployed. For example, a timer or cron job on the workstation that runs
`nix flake update`, builds each host (`nix build path:.#nixosConfigurations.<host>.config.system.build.toplevel`)
and then runs `deploy --skip-checks` for each host, or a CI job with SSH access to the hosts and a copy of your `deploy.nix`. The
job needs the same checkout, including the gitignored `deploy.nix` and
`deployments/<profile>/deploy.nix`, that you deploy from by hand. This repository
does not ship such automation.

### Going back to an earlier configuration

Check out a known-good commit on the workstation and deploy it, or roll back the
host by hand (see [Rolling back by hand](#rolling-back-by-hand)). Nothing on the host
will move it forward again until you next deploy.

### Moving off the nightly rebuild

Hosts installed before this change still have the `nixos-upgrade` timer and a
clone of the repository under `/etc/nixos`. Deploy every host once from a checkout
that contains the change; activation removes `nixos-upgrade.timer`,
`nixos-upgrade.service` and `nixos-upgrade-pull.service`. Confirm with:

```bash
systemctl list-timers 'nixos-upgrade*'   # lists nothing
```

The `/etc/nixos` clone is then no longer used. Once you have copied anything you
still need out of it (uncommitted changes, a `deploy.nix` newer than the workstation's),
delete it, along with the copies of
`deploy.nix` and `deployments/<profile>/` inside it and any deploy key or token you
created for it (for example `/root/.ssh/nixos_deploy`, which should also be removed
from the git host's deploy keys):

```bash
sudo rm -rf /etc/nixos
```

## Disk space (server)

The system disk is one LVM volume group, `lanbat`, with unallocated space held back
(see `hosts/server/disk.nix`).

```bash
sudo server-health        # root and workload usage, free space in the volume group
sudo vgs lanbat           # VFree: unallocated space
sudo lvs lanbat
```

Grow the host root (online):
```bash
sudo lvextend -r -L +50G lanbat/root
```

Grow the workload layer (online, while unlocked):
```bash
sudo lvextend -L +200G lanbat/workload
sudo cryptsetup resize workload       # asks for the workload passphrase
sudo resize2fs /dev/mapper/workload
```

What fills the host root: the Nix store (collected weekly, and during builds when free
space drops below 2 GiB), rootless container images under `/var/lib/containers/<account>`
(dangling images are pruned weekly by `podman-prune-<account>`), and the state of
always-on services such as Frigate recordings and InfluxDB.

```bash
sudo du -xsh /nix/store /var/lib/* 2>/dev/null | sort -h | tail
sudo nix-collect-garbage --delete-older-than 14d
```

Collection is configured per profile under `lanbat.gc` (see `modules/core/gc.nix`).
It is on by default; change the schedule, the retention window, or turn the
scheduled run off entirely:

```nix
lanbat.gc = {
  enable = true;                          # false keeps every generation
  dates = "weekly";
  options = "--delete-older-than 30d";
  minFree = 2 * 1024 * 1024 * 1024;       # collect mid-build below this
  maxFree = 10 * 1024 * 1024 * 1024;      # ... until this much is free
};
```

`minFree`/`maxFree` are a separate safety valve that keeps a build from filling
the disk, so they still apply when `enable = false`. Set `minFree = 0` to turn
that off too. Disabling collection on a host that deploys often will fill the
root filesystem, and a full root cannot build a rollback — prefer a longer
`options` window to switching it off.

## Checking service health

```bash
# Overall status
systemctl status caddy podman-authentik-server podman-authentik-worker
systemctl status jellyfin podman-qbittorrent podman-frigate
systemctl status podman-immich-server podman-homepage podman-searxng
systemctl status postgresql-always-on redis-shared
systemctl status postgresql       # workload instance: only runs while the workload layer is unlocked
systemctl status home-assistant mosquitto samba-smbd tangd.socket
systemctl status vaultwarden grafana influxdb2

# NFS mount status
systemctl status srv-storage-a.automount srv-storage-b.automount
mountpoint /srv/storage/a /srv/storage/b

# On Pi: storage status
lsblk -f
systemctl status nfs-server storage-a-unlock storage-b-unlock
```

## Updating container images

Pin image tags in the service files and bump them deliberately, then deploy. Containers
run rootless, so each account has its own image store. To refresh a floating tag such as
`:latest` by hand:

```bash
sudo -u immich XDG_RUNTIME_DIR=/run/user/$(id -u immich) podman pull ghcr.io/immich-app/immich-server:release
sudo systemctl restart podman-immich-server
```

## Managing Samba users

Samba uses local password storage (smbpasswd). Users must be Linux users first.

```bash
# Add a new user (declare the Linux account in modules/core/human-users.nix first)
sudo smbpasswd -a alice        # sets Samba password
sudo smbpasswd -e alice        # enable if disabled

# Remove a user
sudo smbpasswd -x alice

# List Samba users
sudo pdbedit -L

# Add a human user (declare in modules/core/human-users.nix):
#   lanbat.humanUsers.alice = { uid = 1002; groups = [ "media" ]; };
# Deploy server + Pi, then set Samba password (above).
# Per-user dirs and XFS quotas are applied by human-users.nix and
# user-storage-quotas.service on the Pi.
```

## Tang key management

Control LUKS must be unlocked before any of these commands (`sudo unlock-control`).
`/var/lib/tang` is a bind mount from `/mnt/control/tang` — it is only available
when the control layer is mounted.

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

# Per-user unified quotas (Syncthing, Samba, Nextcloud, …)
sudo quota-report-users

# Set a project limit (example: cap surveillance at 500 GB)
sudo xfs_quota -x -c "limit -p bsoft=500g bhard=550g surveillance" /mnt/storage-a
```

## Accessing Bitmagnet (on-demand)

Bitmagnet starts automatically when you visit `https://bitmagnet.<domain>`.
You'll see a loading page for ~30 seconds on first access.
It stops after 3 days without requests (`onDemand.idleMinutes` in `services/bitmagnet.nix`).

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

# NFS mount events
journalctl -u srv-storage-a.mount -f

# Post-boot Clevis unlock on the Pi
journalctl -u storage-a-unlock -u storage-b-unlock -n 50
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
curl -s http://localhost:8086/health

# Query via CLI (requires the operator token)
# Use localhost, not 127.0.0.1 — the firewall rule for port 8086 can block the latter.
influx query 'from(bucket:"metrics") |> range(start: -1h)' \
  --host http://localhost:8086 \
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

Authentik is pinned to a specific version in `services/authentik/default.nix`
(`authentikVersion`). To upgrade:

1. Check the [Authentik release notes](https://docs.goauthentik.io/docs/releases) —
   Authentik requires sequential upgrades (do not skip major versions).
2. Update `authentikVersion`.
3. Deploy: `deploy --skip-checks path:.#homelab-server`

### Adding a user

The full model — what Nix declares vs. what is manual, the two access mechanisms, and
how each service maps the authentik identity to in-app permissions — is in
[docs/auth.md](auth.md). The day-to-day flow:

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

1. Set `auth = "forward-auth"` and a `subdomain` in the service's `lanbat.services.<name>`.
2. Deploy. The blueprints are generated from the service descriptions
   (`services/authentik/catalogue.nix`), so the service's proxy provider, application
   and embedded-outpost entry come with it, and Authentik applies them on startup.

An OpenID Connect client works the same way: set `oidc.redirectPaths` on the service
and add its `AUTHENTIK_<NAME>_CLIENT_SECRET` to `authentik-oidc-secrets.age`.

Provider names and application slugs are how Authentik recognises its objects, so they
must not change for a service that is already deployed; `catalogue.nix` documents how
they are derived. Removing a service from a host drops it from the blueprints, but
Authentik does not delete objects a blueprint no longer lists: remove them in the UI.

## Vaultwarden

```bash
# Restart Vaultwarden (e.g. after updating vaultwarden-env.age)
sudo systemctl restart vaultwarden

# Logs
journalctl -u vaultwarden -f
```
