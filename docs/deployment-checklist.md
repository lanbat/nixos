# Deployment Checklist

Follow this order exactly. The server must come up before the Pi can unlock its drives.

---

## Phase 0 — Preparation (on your workstation)

### 0a. Enable Nix flakes on your workstation

```bash
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

### 0b. Clone and configure

- [ ] Clone this repo and open the dev shell, which provides `deploy`, `agenix` and
  `nixos-anywhere`:
  ```bash
  git clone <your-repo-url> nixos && cd nixos
  nix develop
  ```
- [ ] Generate your SSH keypair if you don't have one: `ssh-keygen -t ed25519`
- [ ] Create your deployment files:
  ```bash
  cp deploy.nix.example deploy.nix
  mkdir -p deployments/homelab
  cp deployments/homelab/deploy.nix.example deployments/homelab/deploy.nix
  ```
- [ ] Fill in all values in `deploy.nix` and `deployments/homelab/deploy.nix` (gitignored — never commit them). None have
  defaults; the options are documented in `modules/core/settings.nix` and `docs/extensibility.md`.
  - **Deployment:** `domain`, `rootDomain`, `gatewayIp`, `lanSubnet`, `timezone`, `adminSshKey`, …
  - **Server host** (`hosts.server`): `networking.ip`, `networking.interface`, `disks.system`
  - **Storage Pi host** (`hosts.pi-storage`): `networking`, `storage.drives.a/b`
  - **Home Assistant location:** `haLatitude`, `haLongitude`, `haElevation`
  - **Server disk:** `hosts.server.disks.system` — filled in at step 1b
  - **Raspberry Pi drives:** `hosts.pi-storage.storage.drives` — filled in at step 2c
  - **Access:** `adminSshKey` in `deployment` (`cat ~/.ssh/id_ed25519.pub`)
  - **Zigbee dongle:** plug it into any Linux machine and run `lsusb`:
    ```
    Bus 001 Device 003: ID 10c4:ea60 Silicon Labs CP210x UART Bridge
                           ^^^^:^^^^
    → zigbeeVendorId = "10c4"   zigbeeProductId = "ea60"
    ```
- [ ] Configure DNS on your router: point `*.<domain>` to the server's static IP.

### 0c. Create secrets (agenix)

> **CI note:** commit the `.age` files to the repository — they are encrypted and
> safe to commit. Evaluation needs every declared `.age` file to exist; decryption
> only happens on the real machines.

Create your `secrets/secrets.nix` (gitignored — like `deploy.nix`):
```bash
cp secrets/secrets.nix.example secrets/secrets.nix
```
Fill in your workstation public key (`cat ~/.ssh/id_ed25519.pub`) as `admin`. The
`server` and `pi-storage` keys are filled in at steps 1c and 2e.

Generate all purely-random secrets automatically:
```bash
bash secrets/generate-secrets.sh
```

This generates and encrypts: Authentik, Nextcloud, Immich, InfluxDB, Grafana,
and Vaultwarden secrets.  It skips any `.age` file that already exists, so it
is safe to re-run.

The script prints instructions for the secrets it **cannot** generate
automatically — those that depend on external setup:

| Secret | When to fill in |
|---|---|
| `nextcloud-oidc-env.age` | After creating Authentik OIDC app (step 3b) |
| `immich-oidc-env.age` | After creating Authentik OIDC app (step 3b) |
| `grafana-env.age` | Update OAuth secret + InfluxDB token after steps 3b/3h |
| `mosquitto-ha-pass.age` | Choose a password for the HA MQTT user |
| `mosquitto-frigate-pass.age` | Choose a password for the Frigate MQTT user |
| `rclone-frigate-config.age` | Run `rclone config`, paste result (step 3g) |
| `telegraf-token.age` | After deploying InfluxDB (step 3i) |

All of these files **must exist** before installing. Create placeholders now for the
ones you can't fill in yet, and overwrite them at the relevant post-install step.

The mosquitto passwords should be real values now (Home Assistant and Frigate
need them on first start). Pick strong passwords with e.g. `pwgen -s 32 2`.

```bash
cd secrets

# Mosquitto — use real passwords
echo -n "YOUR_HA_PASSWORD"     | agenix -e mosquitto-ha-pass.age
echo -n "YOUR_FRIGATE_PASSWORD" | agenix -e mosquitto-frigate-pass.age

# OIDC — placeholders, overwritten at step 3b
echo "NEXTCLOUD_OIDC_CLIENT_ID=CHANGE_ME
NEXTCLOUD_OIDC_CLIENT_SECRET=CHANGE_ME" | agenix -e nextcloud-oidc-env.age

echo "IMMICH_OAUTH_CLIENT_ID=CHANGE_ME
IMMICH_OAUTH_CLIENT_SECRET=CHANGE_ME" | agenix -e immich-oidc-env.age

# Telegraf — placeholder, overwritten at step 3i
echo "TELEGRAF_INFLUXDB_TOKEN=CHANGE_ME" | agenix -e telegraf-token.age

# rclone — placeholder, overwritten at step 3g
printf "[remote]\ntype = s3\n" | agenix -e rclone-frigate-config.age
```

See `secrets/README.md` for the exact format of each file.

---

## Phase 1 — Server installation (nixos-anywhere)

nixos-anywhere installs over SSH from your workstation: it partitions the disk with
`hosts/server/disk.nix`, formats both LUKS volumes and installs the `server`
configuration. **It erases `serverDisk`.**

### 1a. Boot the NixOS installer

Download the [NixOS minimal ISO](https://nixos.org/download) and boot the server from
USB. On the installer console:

```bash
passwd          # temporary password for the nixos user
ip addr show    # note the IP
```

From your workstation:
```bash
ssh-copy-id nixos@<installer-ip>
```

### 1b. Choose the disk

```bash
ssh nixos@<installer-ip> lsblk -o NAME,SIZE,MODEL
ssh nixos@<installer-ip> ls -l /dev/disk/by-id/
```

Set `serverDisk` in `deployments/homelab/deploy.nix` to the whole-disk entry (no `-partN` suffix), e.g.
`"/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_2TB_S7KHNJ0W123456"`. Don't pick the USB
installer.

The layout gives the host root 150 GiB, the control layer 1 GiB and the workload layer
80% of the rest, leaving about 20% unallocated for growing either later
(`docs/operations.md` § Disk space). Adjust the sizes in `hosts/server/disk.nix` first if
they don't suit your disk. Check that the configuration builds:

```bash
nix build path:.#nixosConfigurations.homelab-server.config.system.build.toplevel
```

### 1c. Create the server's SSH host key

agenix decrypts secrets with the host's SSH key. Creating the key now lets the server
decrypt its secrets on first boot:

```bash
install -d -m 0755 /tmp/server-root/etc/ssh
ssh-keygen -t ed25519 -N "" -C root@server -f /tmp/server-root/etc/ssh/ssh_host_ed25519_key
cat /tmp/server-root/etc/ssh/ssh_host_ed25519_key.pub
```

Put the public key in `secrets/secrets.nix` as `server`, then re-encrypt and commit:
```bash
(cd secrets && agenix -r)
git add secrets/*.age && git commit -m "secrets: add server host key"
```

If you are reinstalling and kept the old host key, put that key pair in
`/tmp/server-root/etc/ssh/` instead and skip the re-encryption.

### 1d. Choose the LUKS passphrases

These are the passphrases you type for `unlock-control` and `unlock-workload`:

```bash
( umask 077
  read -rsp 'control passphrase: ' p && printf '%s' "$p" > /tmp/control.key; echo
  read -rsp 'workload passphrase: ' p && printf '%s' "$p" > /tmp/workload.key; echo )
```

### 1e. Install

```bash
nixos-anywhere --flake path:.#homelab-server \
  --target-host nixos@<installer-ip> \
  --disk-encryption-keys /tmp/control.key /tmp/control.key \
  --disk-encryption-keys /tmp/workload.key /tmp/workload.key \
  --extra-files /tmp/server-root
rm -f /tmp/control.key /tmp/workload.key
```

Store the host key from `/tmp/server-root` offline (or delete it; the server has its
copy), then `rm -rf /tmp/server-root`.

The server reboots into the installed system.

### 1f. First boot

The server boots without any passphrase. Both LUKS layers stay locked.

- SSH in: `ssh admin@<server-ip>` (from `hosts.server.networking.ip`).
- Always-on services start; workload-gated services wait for `unlock-workload`.
- Check: `sudo server-health`

### 1g. Back up LUKS headers (do this before anything else)

```bash
# On the server:
sudo cryptsetup luksHeaderBackup /dev/lanbat/control --header-backup-file /tmp/server-control-luks-header.img
sudo cryptsetup luksHeaderBackup /dev/lanbat/workload --header-backup-file /tmp/server-workload-luks-header.img
sudo chown admin /tmp/server-*-luks-header.img

# From your workstation:
scp admin@<server-ip>:/tmp/server-*-luks-header.img ~/
# Store these files OFFLINE (USB drive, secure physical location).
# A lost header means the volume is unrecoverable even with the passphrase.
```

### 1h. Unlock the control layer and initialise Tang

The fresh control volume needs a directory for Tang's keys, once:

```bash
sudo cryptsetup luksOpen /dev/lanbat/control control-luks
sudo mount /dev/mapper/control-luks /mnt/control
sudo install -d -m 0700 /mnt/control/tang
sudo umount /mnt/control

sudo unlock-control
# Tang generates its key pair on first start (stored in /mnt/control/tang/).
```

Verify Tang:
```bash
curl http://127.0.0.1:7500/adv | jq -r '.keys[].alg'
```

**Back up Tang keys immediately** — see `docs/runbook.md § Backing up Tang keys`.

### 1i. Unlock the workload layer

```bash
sudo unlock-workload
# Workload-gated services start. The first start is slow (container image pulls).
```

Verify:
```bash
sudo server-health
systemctl status caddy podman-authentik-server postgresql
```

The root CA cert is pinned in the repo and available at boot (`/etc/caddy/ca-root.crt`);
Caddy does not need time to generate it.

From now on, deploy changes from your workstation with `deploy path:.#homelab-server`.

---

## Phase 2 — Pi installation

### 2a. Flash the Pi 5 installer image (on your workstation)

> **The generic NixOS aarch64 SD image from nixos.org does not boot a Raspberry Pi 5.**
> Use the installer image from [nixos-raspberrypi](https://github.com/nvmd/nixos-raspberrypi),
> which ships the Raspberry Pi kernel and firmware for the Pi 5.

The project doesn't attach images to its releases. Its "Build Installer Images" CI
workflow publishes them as build artifacts, kept for a limited time. Download the newest
Pi 5 image:

```bash
id=$(gh api 'repos/nvmd/nixos-raspberrypi/actions/artifacts?name=nixos-installer-rpi5-kernel.img.zst' \
  --jq '[.artifacts[] | select(.expired == false)] | sort_by(.created_at) | last | .id')
# The endpoint is called /zip, but it returns the .img.zst file itself.
gh api "repos/nvmd/nixos-raspberrypi/actions/artifacts/$id/zip" > nixos-installer-rpi5-kernel.img.zst
zstd -t nixos-installer-rpi5-kernel.img.zst     # integrity check
```

If no artifact is left, build the image instead. It needs an aarch64 builder or emulation
(on Debian: `sudo apt install qemu-user-binfmt`); the kernel and firmware come from the
project's binary cache:

```bash
nix --accept-flake-config build github:nvmd/nixos-raspberrypi#installerImages.rpi5
```

Flash it to the microSD card. **This erases the card**; check the device with `lsblk`
and unmount any auto-mounted partitions first:

```bash
zstd -dc nixos-installer-rpi5-kernel.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

Insert the card into the Pi 5, connect Ethernet (and a screen for the first boot) and
power it on. The image grows its root partition to fill the card on first boot.

### 2b. SSH into the Pi

The installer generates random login credentials at boot and shows them on the HDMI
screen, together with its address. It also announces itself over mDNS. Log in as root
with those credentials and install your key:

```bash
ssh-copy-id root@<pi-ip>
```

### 2c. Partition and format storage drives

> **IMPORTANT**: The Pi boots from microSD. The two NVMe storage drives are
> separate (connected via M.2 HAT or USB NVMe adapter).

```bash
# On the Pi. NVMe drives appear as /dev/nvme0n1, /dev/nvme1n1;
# microSD appears as /dev/mmcblk0 — do NOT touch that one.
lsblk

# Get the stable by-id paths for both NVMe drives:
ls -la /dev/disk/by-id/ | grep nvme | grep -v part

# Encrypt and format Drive A
sudo cryptsetup luksFormat --type luks2 /dev/disk/by-id/DRIVE_A_ID
sudo cryptsetup luksOpen /dev/disk/by-id/DRIVE_A_ID storage-a
sudo mkfs.xfs -L storage-a /dev/mapper/storage-a

# Encrypt and format Drive B
sudo cryptsetup luksFormat --type luks2 /dev/disk/by-id/DRIVE_B_ID
sudo cryptsetup luksOpen /dev/disk/by-id/DRIVE_B_ID storage-b
sudo mkfs.xfs -L storage-b /dev/mapper/storage-b
```

These commands put LUKS on the whole disk. A drive that instead carries a
partition table with LUKS on a partition also works: the unlock service checks
the whole disk first and then its partitions, and uses whichever is really a
LUKS device. Keep naming the **whole disk** in `deploy.nix` either way, because
`modules/pi/telegraf.nix` reads SMART counters from that same path.

Set `piStorageDriveA` and `piStorageDriveB` in `deployments/homelab/deploy.nix` to the by-id filenames
(without the `/dev/disk/by-id/` prefix).

### 2d. Bind Clevis to Tang

```bash
# The Pi must reach the server on port 7500: curl http://SERVER_IP:7500/adv

sudo clevis luks bind -d /dev/disk/by-id/DRIVE_A_ID tang \
  '{"url":"http://SERVER_IP:7500"}' -y
sudo clevis luks bind -d /dev/disk/by-id/DRIVE_B_ID tang \
  '{"url":"http://SERVER_IP:7500"}' -y

# Test unlock:
sudo clevis luks unlock -d /dev/disk/by-id/DRIVE_A_ID -n storage-a
```

### 2e. Add the Pi's host key to the secrets

```bash
ssh root@<pi-ip> cat /etc/ssh/ssh_host_ed25519_key.pub
```

The installer keeps this key when you switch to your configuration in step 2f, because
it stays on the card.

Put it in `secrets/secrets.nix` as `pi-storage` (matching `hosts.pi-storage`),
ensure `telegraf-token.age` and `ha-voice-token.age` use `allKeys`, then
re-encrypt and commit:
```bash
(cd secrets && agenix -r)
git add secrets/*.age && git commit -m "secrets: add pi host key"
```

### 2f. First switch to the Pi configuration

The installer image is a normal, mutable NixOS system on the card, so you switch it to
your configuration in place rather than reinstalling. It has no `admin` user yet, so the
first switch logs in as root and builds on the Pi itself (no emulation needed):

```bash
nix run nixpkgs#nixos-rebuild -- switch --flake path:.#homelab-pi-storage \
  --target-host root@<pi-ip> --build-host root@<pi-ip>
```

The Pi configuration boots the same way as the installer: `hosts/pi/hardware.nix` imports
nixos-raspberrypi's Raspberry Pi 5 modules and sets
`boot.loader.raspberry-pi.bootloader = "kernel"`. The Pi is built with nixos-raspberrypi's
pinned nixpkgs (see `flake.nix`), so its kernel comes from that project's binary cache.

Set `hosts.pi-storage.networking.interface` in `deployments/homelab/deploy.nix` first (the Pi 5's on-board Ethernet is `end0`). If
`hosts.pi-storage.networking.ip` differs from the installer's DHCP address, use `boot` instead of `switch` and
reboot, so the address doesn't change in the middle of the SSH session:

```bash
nix run nixpkgs#nixos-rebuild -- boot --flake path:.#homelab-pi-storage \
  --target-host root@<pi-ip> --build-host root@<pi-ip>
ssh root@<pi-ip> reboot
```

After the reboot, log in as `admin` on the Pi's static IP; the configuration disables root login.

From now on, deploy with `deploy path:.#homelab-pi-storage`.

### 2g. First Pi boot

- Pi should auto-unlock drives via Clevis/Tang (server must be running).
- Verify: `lsblk` should show storage-a and storage-b as open mappers.
- Verify NFS: `showmount -e localhost`
- Verify Snapclient: `systemctl status snapclient`
- With the TV plugin (`lanbatPlugins.tv`) enabled on the storage Pi, Kodi should
  appear on HDMI (if a screen is attached). Holding a controller's Guide button
  for 2 seconds switches to EmulationStation and back.

### 2h. Clone the config repo on each machine

Unattended upgrades rebuild from a local copy of this repo at `/etc/nixos`.
Clone it on both machines now:

```bash
# On the server
ssh admin@server
sudo git clone <your-repo-url> /etc/nixos
sudo cp /path/to/deploy.nix /etc/nixos/deploy.nix
sudo cp -r /path/to/deployments/homelab /etc/nixos/deployments/homelab

# On the Pi
ssh admin@pi5
sudo git clone <your-repo-url> /etc/nixos
sudo cp /path/to/deploy.nix /etc/nixos/deploy.nix
sudo cp -r /path/to/deployments/homelab /etc/nixos/deployments/homelab
```

Set the upstream branch on each clone (use your default branch name):

```bash
sudo git -C /etc/nixos branch --set-upstream-to=origin/master
```

If your repo is **private**, configure git credentials before auto-upgrade
will be able to pull:

```bash
# Option A — HTTPS token (simpler)
sudo git -C /etc/nixos remote set-url origin https://<token>@github.com/user/repo.git

# Option B — SSH deploy key (more secure)
sudo ssh-keygen -t ed25519 -f /root/.ssh/nixos_deploy -N ""
# Add /root/.ssh/nixos_deploy.pub as a read-only deploy key in your git host
sudo git -C /etc/nixos remote set-url origin git@github.com:user/repo.git
```

If your repo is **public**, no credentials are needed — HTTPS clone works as-is.

---

## Phase 3 — Post-install configuration

### 3a. Re-key agenix secrets when a host key changes

Steps 1c and 2e already made both hosts recipients. If a host is reinstalled with a new
SSH host key, update `secrets/secrets.nix`, then:

```bash
(cd secrets && agenix -r)
deploy path:.#homelab-server
deploy path:.#homelab-pi-storage
```

### 3b. Authentik initial setup

Visit `https://auth.<domain>/if/flow/initial-setup/` and create the initial
admin account.

#### Automated: providers, applications, and outpost

All Authentik providers, applications, and the embedded outpost are configured
automatically via blueprints, generated from the service descriptions of the
services on the server (`services/authentik/catalogue.nix`).
The blueprints are applied by Authentik on every startup — no manual UI work
needed for the Authentik side.

To wire the shared OIDC client secrets, run the generator script:

```bash
bash secrets/generate-oidc-secrets.sh
```

This creates `authentik-oidc-secrets.age` and updates `grafana-env.age`,
`nextcloud-oidc-env.age`, and `immich-oidc-env.age` with matching values.
The script prints the client credentials needed for Home Assistant and Jellyfin
(see manual steps below).

Deploy to apply the new secrets:

```bash
deploy path:.#homelab-server
```

After the deploy, Authentik restarts and the blueprints run automatically.
Grafana and Immich OIDC come up fully automatically.  Nextcloud needs one
extra step (see below).

#### Nextcloud — install the OIDC app

The `user_oidc` Nextcloud app must be installed before OIDC will work.
Log in at `https://cloud.<domain>` as the local `admin`, then either:

- **Via the Nextcloud Apps UI:** Apps → Search "OpenID Connect user backend" → Install & Enable.
- **Via occ:** `sudo -u nextcloud nextcloud-occ app:install user_oidc`

Once the app is enabled, the `nextcloud-oidc-setup` systemd service runs
automatically and registers the Authentik provider.  No further steps needed.

#### Home Assistant — bootstrap secret and SSO users

1. Create `secrets/hass-bootstrap-env.age` (one `KEY=value` per line):

   ```
   OWNER_USERNAME=akadmin
   OWNER_PASSWORD=<random break-glass password>
   ```

2. Add Authentik usernames that should land in HA without a second login to
   `lanbat.homeAssistant.ssoUsers` in `deployments/homelab/deploy.nix` (default: `[ "akadmin" ]`).
   Usernames must match Authentik exactly.

3. Deploy.  `home-assistant-bootstrap` completes first-run onboarding and
   creates the SSO users.  Entitled Authentik users opening `https://ha.<domain>`
   are authenticated via forward-auth + header auth.

4. Grant users access to the **Home Assistant** application in Authentik
   (Applications → Home Assistant → Policy / group bindings).

#### Jellyfin — automatic setup

`jellyfin-bootstrap` completes first-run onboarding on deploy:

- Admin account from `hass-bootstrap-env.age` (same break-glass credentials as HA/Immich)
- Media libraries for every Pi folder except `adult/` (Samba-only), `incomplete/`
  (active downloads), and `roms/` (RomM): Movies, TV, Music Videos, Music,
  Documentaries, Audiobooks, Books, Gym, Games, Misc
- Plugins: Open Subtitles, Trakt, SSO Authentication
- Authentik OIDC provider (`authentik`) from `authentik-oidc-secrets.age`
- Realtime monitoring disabled (NFS cannot use inotify); library scan every 2 hours
  plus a full scan on each bootstrap run

Grant users access to the **Jellyfin** application in Authentik.  Adult content
is only available via the hidden Samba `private` share (`@private` group).

### 3c. Samba user setup

```bash
# On server, create Samba password for each user
sudo smbpasswd -a admin
# Repeat for other users.

# User storage trees (files/, sync/, cloud/, photos/) are created by
# human-users.nix on the server and user-storage-quotas.service on the Pi.
# Re-deploy both hosts after adding lanbat.humanUsers entries.
```

### 3d. XFS quota setup

```bash
# SSH to Pi, then:
sudo bash /run/current-system/sw/bin/quota-setup.sh

# Set actual limits:
sudo xfs_quota -x -c "limit -p bsoft=500g bhard=550g surveillance" /mnt/storage-a
sudo xfs_quota -x -c "limit -p bsoft=2t   bhard=2.2t downloads"    /mnt/storage-a
sudo xfs_quota -x -c "limit -p bsoft=1t   bhard=1.1t backups"      /mnt/storage-b
```

### 3e. Install CA on your devices

The internal root CA is pinned in the repository (`secrets/caddy-ca-root.crt` +
`secrets/caddy-ca-root-key.age`) so a host-root reinstall does not mint a new
root. Install the **current** root once on every client that uses the HTTPS
services.

Visit `https://ca.<domain>` from each device (or download
`https://ca.<domain>/root.crt` with `curl -k` if the browser does not trust the
CA yet). Follow the OS-specific instructions on the page.

After a **fresh** install (first time only for this root), redistribute the CA
to phones, laptops and other devices. A routine `deploy` or host-root reinstall
does **not** require re-trusting unless the root key material is deliberately
rotated.

See `docs/security.md` (Internal CA trust on client devices) for Debian/Ubuntu
removal of old roots, browser NSS stores, and what to do after a deliberate root
rotation. If a browser still warns after install, see the same doc (TLS chain
troubleshooting) — a server-side intermediate cleanup is only needed when the
served chain does not verify against the pinned root.

### 3f. Configure Frigate cameras

Update the cameras in `services/frigate.nix` and deploy.

### 3g. Set up rclone for Frigate cloud sync

Decrypt and edit the rclone config:
```bash
agenix -d secrets/rclone-frigate-config.age > /tmp/rclone.conf
# Edit /tmp/rclone.conf with your cloud storage credentials.
agenix -e secrets/rclone-frigate-config.age < /tmp/rclone.conf
rm /tmp/rclone.conf
```

### 3h. Grafana initial setup

After setting the Authentik OIDC client secret in `grafana-env.age` (covered in step 3b):

```bash
deploy path:.#homelab-server
```

Visit `https://grafana.<domain>` — the InfluxDB datasource is provisioned
automatically. Log in with Authentik or the local `admin` break-glass account.

### 3i. Telegraf token setup

Telegraf needs a write-only InfluxDB token (separate from the operator token
used by Grafana).

1. Open the InfluxDB UI through an SSH tunnel (it is not exposed via Caddy):
   `ssh -L 8086:localhost:8086 admin@<server-ip>`, then `http://localhost:8086`.
2. **Data → API Tokens → Generate API Token → Custom API Token**
   - Description: `telegraf`
   - Buckets: Write → `metrics`
3. Copy the generated token.
4. Store it on your workstation:
   ```bash
   cd secrets
   agenix -e telegraf-token.age
   # File content: TELEGRAF_INFLUXDB_TOKEN=<paste token here>
   ```
5. Deploy:
   ```bash
   deploy path:.#homelab-server
   deploy path:.#homelab-pi-storage
   ```
6. Verify both agents are running and writing:
   ```bash
   systemctl status telegraf              # on server
   ssh admin@pi5 systemctl status telegraf  # on Pi
   ```
   In Grafana, run a Flux query against the `metrics` bucket — you should see
   `cpu`, `mem`, `disk` measurements tagged with each hostname.

### 3j. Vaultwarden initial setup

The `vaultwarden-env.age` secret was created in Phase 0c.
Visit `https://vault.<domain>/admin` to access the admin panel.
Invite users from there — open signup is disabled.

### 3k. Syncthing initial setup

Visit `https://sync.<domain>` (protected by Authentik forward auth).

1. Set a GUI username and password under **Settings → GUI** (optional second layer inside Syncthing).
2. Note this device's ID (**Actions → Show ID**) — share it with devices you want to sync with.
3. Add remote devices via **Add Remote Device**.
4. The default sync folder is `/srv/storage/b/users/admin/sync/` (personal storage,
   counted toward the admin user's XFS project quota — not the shared 200 GB cap).
   If you already synced to `/srv/storage/b/syncthing/`, move that data into the new path
   before or after deploy. Add or adjust folders in `services/syncthing.nix` or the web UI.
   If you add a folder on Pi storage Drive A, add `"a"` to `nfs.drives` in
   `services/syncthing.nix`.

### 3l. Wyoming voice assistant

> **Hardware required:** a USB microphone on the server and on the Pi. The
> default is the PlayStation Eye (`lanbat.voiceSatellite.microphone.usbId` in
> `modules/core/voice-satellite.nix`). Replies play on the server's internal
> speaker and on the Pi's HDMI output, where they mix with Snapcast: the music
> turns down while the assistant listens and answers (`modules/pi/audio.nix`).

`home-assistant-post-setup` adds the Wyoming services and both satellites to
Home Assistant, the conversation agent for `lanbat.haLlm` (API key from
`ha-llm-api-key.age`), and a preferred **Voice** pipeline: wake word
`okay_nabu`, faster-whisper, piper, Home Assistant's local intents first, then
the LLM.

With `lanbat.voiceRooms` set, a satellite hands each reply to Home Assistant,
which speaks it as an announcement on the Music Assistant players in the
satellite's room; Music Assistant turns their music down meanwhile. The
satellite plays a reply itself only when its room has no players, or Home
Assistant is out of reach. `home-assistant-post-setup` adds the satellites'
"Voice satellites" user and token, and `music-assistant-setup` connects Music
Assistant to the snapserver, so every Snapcast client becomes a player.

1. Verify the services on the server and the Pi:
   ```bash
   systemctl status wyoming-openwakeword wyoming-faster-whisper-main wyoming-piper-main wyoming-satellite
   journalctl -u home-assistant-post-setup
   ssh admin@<pi-ip> systemctl status wyoming-satellite
   ```
   A satellite logging "no sound card with USB ID" can't find its microphone:
   compare `lsusb` with `microphone.usbId`.

2. For replies on the room's speakers, create the satellites' token before
   deploying, and commit both files:
   ```bash
   bash secrets/generate-ha-voice-token.sh
   ```
   Then give each speaker its room: **Settings → Devices & services → Music
   Assistant**, open the player's device and set its area. The players in a
   satellite's room speak its replies, so a new speaker joins by getting an area.

3. Choose what the assistant may control: **Settings → Voice assistants →
   Expose**. The LLM only sees and controls exposed entities.

4. Test: say **"Okay Nabu"** near either microphone, then ask something.
   **Settings → Voice assistants → Voice → ⋮ → Debug** shows each run.

> **Tip:** faster-whisper and piper download their models on first start, and
> an LLM endpoint that scales to zero is slow to answer its first request after
> being idle. Commands Home Assistant understands itself don't wait for the LLM.
> `home-assistant-post-setup` sets each satellite's **Finished speaking
> detection** to **Aggressive** (0.25 s silence after a command). If a satellite
> still feels slow to react, check that setting under **Settings → Devices &
> services → Wyoming → Pi Satellite**.

### 3m. Music Assistant

Music Assistant is the music controller; Snapcast remains the distribution layer.

1. Visit `https://music.<domain>` (Authentik forward-auth).
2. **Snapcast player provider** — Settings → Player Providers → Add → Snapcast:
   - Enable **Use existing Snapserver**.
   - Host: `127.0.0.1`, control port: `1705`.
   - Do **not** use MA's built-in snapserver (it conflicts with the declarative
     `services.snapserver` on the same ports).
3. **Local filesystem music provider** — Settings → Music Providers → Add →
   Local Filesystem:
   - Path: `/srv/storage/b/media/music` (NFS from Pi; scans fail gracefully
     while the Pi is down).
4. **Base URL** — Settings → System → set Base URL to `https://music.<domain>`.
5. **Home Assistant** — Settings → Devices & Services → Add Integration →
   Music Assistant → URL `http://127.0.0.1:8095`.
   - Keep HA's legacy **slimproto** (Squeezebox) integration disabled.
6. Verify the Pi snapclient appears as a Snapcast player in MA, then play a
   test track. Confirm sync at `https://audio.<domain>` (Snapcast web UI).

> The `music.<domain>` subdomain may be consolidated to `audio.<domain>` when
> Snapcast's own web UI is retired in a later change.

### 3n. Snapcast (distribution)

Snapserver runs declaratively on the server (ports 1704/1705). Music Assistant
feeds it via the control API — no manual FIFO wiring is needed.

Verify Snapclient on the Pi: `systemctl status snapclient`. The client should
appear in both the Snapcast web UI (`https://audio.<domain>`) and Music Assistant.

---

### 3o. RomM

RomM starts on the first visit to `https://romm.<domain>` (after the Authentik login)
and stops after 30 minutes idle.

1. On the first visit, RomM's setup wizard creates the admin account.
2. The library is the Pi's `media/roms` folder on drive B, in ES-DE's layout
   (`roms/<system>`, the same folders EmulationStation reads). Scan it from
   Library → Scan.
3. `config.yml` is seeded on the first start (`/var/lib/romm/config/`); change platform
   bindings and exclusions from RomM's settings.
4. Arcade games in the browser: RomM's arcade folder shows zip copies of the MAME
   sets (`media/roms-browser/mame`), which `romm-browser-romsets` builds hourly with
   each game's parent and BIOS files. In the player, pick the **FinalBurn Neo** core
   once per browser; RomM remembers it, and its default, MAME 2003, crashes on these
   sets. Dreamcast games don't run in the browser; play them on the TV.

### 3p. Bluetooth sensors (optional)

> **Hardware required:** a USB Bluetooth adapter on the server. Keep it away
> from the Zigbee dongle: both use 2.4 GHz.

`home-assistant-post-setup` adds Home Assistant's Bluetooth config entry for
each adapter BlueZ reports. Sensors reflashed to BTHome (pvvx firmware) are
then discovered without further setup.

Stock-firmware Xiaomi sensors broadcast encrypted and need a bind key per
device, which you can get locally from
[Mi Activation](https://atc1441.github.io/Temp_universal_mi_activate.html):

1. Put one `<MAC> <bindkey> [entry title]` line per device in
   `ha-xiaomi-ble.age` (`agenix -e ha-xiaomi-ble.age`) and set
   `deployment.haXiaomiBle = true` in `deploy.nix`.
2. Deploy. `home-assistant-post-setup` adds a `xiaomi_ble` config entry for each
   device not yet in Home Assistant:
   ```bash
   journalctl -u home-assistant-post-setup | grep -i xiaomi
   ```

## Phase 4 — Ongoing

- Deploy changes immediately: `deploy path:.#homelab-server` / `deploy path:.#homelab-pi-storage`.
- Update inputs: `nix flake update`, commit `flake.lock`, `git push`
  (`docs/operations.md` § Updating). Hosts auto-upgrade nightly from `/etc/nixos`.
- Back up the Tang key directory: `docs/runbook.md` § Backing up Tang keys.
- Test Pi unlock after a server reboot to verify Clevis/Tang works.
- Pin container image versions when stability matters.
- **Nextcloud major upgrades:** check the running version with
  `sudo -u nextcloud nextcloud-occ status`, back up (`docs/backup.md`), then bump
  `services.nextcloud.package` one major at a time — full steps in
  `docs/runbook.md` § Nextcloud major version upgrade.
