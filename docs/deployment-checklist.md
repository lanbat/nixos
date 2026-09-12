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
- [ ] Create your local settings file: `cp local.nix.example local.nix`
- [ ] Fill in all values in `local.nix` (gitignored — never commit it). None have
  defaults; the options are documented in `modules/core/settings.nix`.
  - **Network:** `serverIp`, `piIp`, `gatewayIp`, `lanSubnet`, `serverHostname`, `piHostname`
  - **DNS:** `domain` (e.g. `"home.example.com"`), `rootDomain` (e.g. `"example.com"`)
  - **NFS:** `nfsIdmapdDomain` (any string, e.g. `"home.lan"`)
  - **System:** `timezone`, `phoneRegion`
  - **Home Assistant location:** `haLatitude`, `haLongitude`, `haElevation`
  - **Server disk:** `serverDisk` — filled in at step 1b
  - **Raspberry Pi drives:** `piStorageDriveA`, `piStorageDriveB` — filled in at step 2c
  - **Access:** `adminSshKey` (`cat ~/.ssh/id_ed25519.pub`)
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

Create your `secrets/secrets.nix` (gitignored — like `local.nix`):
```bash
cp secrets/secrets.nix.example secrets/secrets.nix
```
Fill in your workstation public key (`cat ~/.ssh/id_ed25519.pub`) as `admin`. The
`server` and `pi` keys are filled in at steps 1c and 2e.

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

Set `serverDisk` in `local.nix` to the whole-disk entry (no `-partN` suffix), e.g.
`"/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_2TB_S7KHNJ0W123456"`. Don't pick the USB
installer.

The layout gives the host root 150 GiB, the control layer 1 GiB and the workload layer
80% of the rest, leaving about 20% unallocated for growing either later
(`docs/operations.md` § Disk space). Adjust the sizes in `hosts/server/disk.nix` first if
they don't suit your disk. Check that the configuration builds:

```bash
nix build path:.#nixosConfigurations.server.config.system.build.toplevel
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
nixos-anywhere --flake path:.#server \
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

- SSH in: `ssh admin@<serverIp>`.
- Always-on services start; workload-gated services wait for `unlock-workload`.
- Check: `sudo server-health`

### 1g. Back up LUKS headers (do this before anything else)

```bash
# On the server:
sudo cryptsetup luksHeaderBackup /dev/lanbat/control --header-backup-file /tmp/server-control-luks-header.img
sudo cryptsetup luksHeaderBackup /dev/lanbat/workload --header-backup-file /tmp/server-workload-luks-header.img
sudo chown admin /tmp/server-*-luks-header.img

# From your workstation:
scp admin@<serverIp>:/tmp/server-*-luks-header.img ~/
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

Wait for Caddy to generate the CA cert (usually 10–30 seconds after start).

From now on, deploy changes from your workstation with `deploy path:.#server`.

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

Set `piStorageDriveA` and `piStorageDriveB` in `local.nix` to the by-id filenames
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

Put it in `secrets/secrets.nix` as `pi`, add `pi` to the recipients of
`telegraf-token.age`, then re-encrypt and commit:
```bash
(cd secrets && agenix -r)
git add secrets/*.age && git commit -m "secrets: add pi host key"
```

### 2f. First switch to the Pi configuration

The installer image is a normal, mutable NixOS system on the card, so you switch it to
your configuration in place rather than reinstalling. It has no `admin` user yet, so the
first switch logs in as root and builds on the Pi itself (no emulation needed):

```bash
nix run nixpkgs#nixos-rebuild -- switch --flake path:.#pi \
  --target-host root@<pi-ip> --build-host root@<pi-ip>
```

The Pi configuration boots the same way as the installer: `hosts/pi/hardware.nix` imports
nixos-raspberrypi's Raspberry Pi 5 modules and sets
`boot.loader.raspberry-pi.bootloader = "kernel"`. The Pi is built with nixos-raspberrypi's
pinned nixpkgs (see `flake.nix`), so its kernel comes from that project's binary cache.

Set `piInterface` in `local.nix` first (the Pi 5's on-board Ethernet is `end0`). If
`piIp` differs from the installer's DHCP address, use `boot` instead of `switch` and
reboot, so the address doesn't change in the middle of the SSH session:

```bash
nix run nixpkgs#nixos-rebuild -- boot --flake path:.#pi \
  --target-host root@<pi-ip> --build-host root@<pi-ip>
ssh root@<pi-ip> reboot
```

After the reboot, log in as `admin` on `piIp`; the configuration disables root login.

From now on, deploy with `deploy path:.#pi`.

### 2g. First Pi boot

- Pi should auto-unlock drives via Clevis/Tang (server must be running).
- Verify: `lsblk` should show storage-a and storage-b as open mappers.
- Verify NFS: `showmount -e localhost`
- Verify Snapclient: `systemctl status snapclient`
- With `piTvFrontend` on, Kodi should appear on HDMI (if a screen is attached). Holding a
  controller's Guide button for 2 seconds switches to EmulationStation and back.

---

## Phase 3 — Post-install configuration

### 3a. Re-key agenix secrets when a host key changes

Steps 1c and 2e already made both hosts recipients. If a host is reinstalled with a new
SSH host key, update `secrets/secrets.nix`, then:

```bash
(cd secrets && agenix -r)
deploy path:.#server
deploy path:.#pi
```

### 3b. Authentik initial setup

Visit `https://auth.<domain>/if/flow/initial-setup/` and create the initial
admin account.

#### Automated: providers, applications, and outpost

All Authentik providers, applications, and the embedded outpost are configured
automatically via blueprints (`services/authentik/blueprints.nix`).
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
deploy path:.#server
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

#### Home Assistant — manual UI setup

1. Install the HACS integration from the [HACS store](https://hacs.xyz) or use
   the built-in "Home Assistant OAuth2" integration if available.
2. Settings → Devices & Services → Add Integration → search "Authentik".
3. Use the values printed by `generate-oidc-secrets.sh`:
   - client_id: `home-assistant`
   - client_secret: (from the script output)
   - discovery URL: `https://auth.<domain>/application/o/home-assistant/.well-known/openid-configuration`

#### Jellyfin — manual UI setup

1. Dashboard → Plugins → Catalog → **SSO Authentication** → Install. Restart Jellyfin.
2. Dashboard → SSO-Auth → Add provider with values from `generate-oidc-secrets.sh`:
   - Provider name: `authentik`
   - client_id: `jellyfin`
   - client_secret: (from the script output)
   - Authorization URL: `https://auth.<domain>/application/o/authorize/`
   - Token URL: `https://auth.<domain>/application/o/token/`
   - Userinfo URL: `https://auth.<domain>/application/o/userinfo/`

### 3c. Samba user setup

```bash
# On server, create Samba password for each user
sudo smbpasswd -a admin
# Repeat for other users.

# Create user home directories on Pi storage (if not already created by storage init):
sudo mkdir -p /srv/storage/b/users/admin
sudo chown admin:media /srv/storage/b/users/admin
sudo chmod 0700 /srv/storage/b/users/admin
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

Visit `https://ca.<domain>` from each device.
Follow the OS-specific instructions on the page.

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
deploy path:.#server
```

Visit `https://grafana.<domain>` — the InfluxDB datasource is provisioned
automatically. Log in with Authentik or the local `admin` break-glass account.

### 3i. Telegraf token setup

Telegraf needs a write-only InfluxDB token (separate from the operator token
used by Grafana).

1. Open the InfluxDB UI through an SSH tunnel (it is not exposed via Caddy):
   `ssh -L 8086:127.0.0.1:8086 admin@<serverIp>`, then `http://localhost:8086`.
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
   deploy path:.#server
   deploy path:.#pi
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

1. Set a GUI username and password under **Settings → GUI**.
2. Note this device's ID (**Actions → Show ID**) — share it with devices you want to sync with.
3. Add remote devices via **Add Remote Device**.
4. The default sync folder is `/srv/storage/b/syncthing/`. Add or adjust folders as needed.
   If you add a folder on Pi storage Drive A, add `"a"` to `nfs.drives` in
   `services/syncthing.nix`.

### 3l. Wyoming voice assistant

> **Hardware required:** a USB microphone (or microphone HAT) and speaker
> connected to the Pi.

1. Verify the Wyoming services are running on the server:
   ```bash
   systemctl status wyoming-openwakeword
   systemctl status wyoming-faster-whisper-main
   systemctl status wyoming-piper-main
   ```

2. Verify the satellite is running on the Pi:
   ```bash
   ssh admin@pi5 systemctl status wyoming-satellite
   ```
   If it fails with an audio error, the default ALSA device may not match your
   hardware.  Run `ssh admin@pi5 arecord -l` to list capture devices and adjust
   `microphone.command` in `modules/pi/wyoming-satellite.nix`.

3. In Home Assistant: **Settings → Devices & Services → Add Integration → Wyoming**
   Add each service:
   - Satellite: `<pi-ip>:10700`
   - Wake word: `127.0.0.1:10300`
   - Speech-to-text: `127.0.0.1:10301`
   - Text-to-speech: `127.0.0.1:10302`

4. Create a voice assistant pipeline:
   **Settings → Voice Assistants → Add Assistant**
   - Wake word engine: openwakeword → model: `ok_nabu`
   - Speech-to-text: faster-whisper / main
   - Text-to-speech: piper / main
   - Conversation agent: Home Assistant

5. Assign the pipeline to the Pi satellite:
   **Settings → Devices & Services → Wyoming → Pi Satellite → Configure**
   Select the pipeline you just created.

6. Test: say **"Ok nabu"** near the Pi mic, then ask a question.
   The satellite LED (if any) or the HA logbook will confirm detection.

> **Tip:** faster-whisper and piper download their models on first start.
> Allow a minute or two for the first pipeline run — subsequent runs are fast.

### 3m. Snapcast audio source

Snapcast streams whatever is written to `/run/snapserver/main.fifo` on the server.
Wire an audio player to that pipe — see the comments in
`services/snapcast.nix` for examples (MPD, librespot, shairport-sync).

Until a source is connected, the pipe is silent but Snapclient on the Pi will
connect and wait. Verify the client is connected at `https://audio.<domain>`.

---

## Phase 4 — Ongoing

- Deploy changes: `deploy path:.#server` / `deploy path:.#pi`.
- Update inputs: `nix flake update`, check, deploy, commit `flake.lock`
  (`docs/operations.md` § Updating). Hosts don't upgrade themselves.
- Back up the Tang key directory: `docs/runbook.md` § Backing up Tang keys.
- Test Pi unlock after a server reboot to verify Clevis/Tang works.
- Pin container image versions when stability matters.
