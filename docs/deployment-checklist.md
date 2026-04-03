# Deployment Checklist

Follow this order exactly. The server must come up before the Pi can unlock its drives.

---

## Phase 0 — Preparation (on your workstation)

### 0a. Enable Nix experimental features on your workstation

The flake and `nix shell` / `nix build` commands require `nix-command` and
`flakes` to be enabled.  The managed machines get this via
`modules/common/base.nix`, but your workstation needs it separately.

```bash
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

Verify it works:
```bash
nix shell nixpkgs#hello --command hello
# Hello, world!
```

> **Existing repo upgrade:** if you previously had `secrets/secrets.nix`
> tracked in git, stop tracking it:
> ```bash
> git rm --cached secrets/secrets.nix
> git commit -m "stop tracking secrets/secrets.nix (now gitignored)"
> ```

### 0b. Clone and configure

- [ ] Clone this repo
  ```bash
  git clone <your-repo-url> nixos && cd nixos
  ```
- [ ] Generate your SSH keypair if you don't have one: `ssh-keygen -t ed25519`
- [ ] Create your local settings file: `cp local.nix.example local.nix`
- [ ] Fill in all values in `local.nix` (this file is gitignored — never commit it):
  - **Network:**
    - `serverIp` — server static IPv4 (e.g. `"192.168.1.10"`)
    - `piIp` — Pi static IPv4 (e.g. `"192.168.1.11"`)
    - `gatewayIp` — router/gateway IPv4 (e.g. `"192.168.1.1"`)
    - `lanSubnet` — your LAN CIDR (e.g. `"192.168.1.0/24"`)
    - `serverHostname` — hostname for the server (default: `"server"`)
    - `piHostname` — Pi hostname used as NFS target (default: `"pi5"`; or set to `piIp`)
  - **DNS:**
    - `domain` — wildcard DNS subdomain (e.g. `"home.example.com"`)
    - `rootDomain` — parent DNS zone (e.g. `"example.com"`)
  - **NFS:**
    - `nfsIdmapdDomain` — NFSv4 ID mapping domain, must match on both machines (e.g. `"home.lan"`)
  - **System:**
    - `timezone` — your timezone (e.g. `"Europe/London"`)
    - `phoneRegion` — ISO 3166-1 alpha-2 country code for Nextcloud (e.g. `"GB"`)
  - **Home Assistant location:**
    - `haLatitude` — decimal degrees (e.g. `"51.5"`)
    - `haLongitude` — decimal degrees (e.g. `"-0.1"`)
    - `haElevation` — metres above sea level (e.g. `50`)
  - **Access:**
    - `adminSshKey` — your SSH public key (`cat ~/.ssh/id_ed25519.pub`)
  - **Zigbee dongle** — plug the dongle into the **server** and run:
    ```bash
    # Find the by-id filename (copy everything after /dev/serial/by-id/):
    ls /dev/serial/by-id/
    # Example output: usb-Silicon_Labs_Sonoff_Zigbee_3.0_USB_Dongle_Plus_0001-if00-port0
    # → zigbeeDongle = "usb-Silicon_Labs_Sonoff_Zigbee_3.0_USB_Dongle_Plus_0001-if00-port0"

    # Find the USB vendor and product IDs:
    lsusb
    # Example output: Bus 001 Device 003: ID 10c4:ea60 Silicon Labs CP210x UART Bridge
    #                                        ^^^^:^^^^
    # → zigbeeVendorId = "10c4"   zigbeeProductId = "ea60"
    ```
- [ ] Configure DNS on your router: point `*.<domain>` to the server's static IP.
  This must be done before any service URLs will resolve.

### 0c. Install agenix on your workstation

```bash
nix shell github:ryantm/agenix
# Or add it to your personal flake/profile permanently.
```

### 0d. Create secrets (agenix)

> **Chicken-and-egg note:** agenix encrypts secrets to the host SSH key, but the
> host doesn't exist yet. Encrypt all secrets with your admin key only for now.
> After first boot, add the host keys to `secrets/secrets.nix` and run `agenix -r`.

> **CI note:** commit the `.age` files to the repository — they are encrypted and
> safe to commit. The GitHub Actions workflow evaluates the NixOS configurations,
> which requires the `.age` files to exist as paths in the store. Decryption only
> happens at activation time on the real machines, never in CI.

First, create your `secrets/secrets.nix` (gitignored — like `local.nix`):
```bash
cp secrets/secrets.nix.example secrets/secrets.nix
```
Fill in your workstation public key (`cat ~/.ssh/id_ed25519.pub`) as `admin`.
Leave `server` and `pi` as placeholders for now — you'll fill them in at step 3a.

Generate all purely-random secrets automatically:
```bash
bash secrets/generate-secrets.sh
```

This generates and encrypts: Authentik, Nextcloud, Immich, InfluxDB, Grafana,
and Vaultwarden secrets.  It skips any `.age` file that already exists, so it
is safe to re-run.

The script will print instructions for the secrets it **cannot** generate
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

Then commit the generated `.age` files:
```bash
git add secrets/*.age && git commit -m "add initial secrets"
```
```

See `secrets/README.md` for the exact format of each file.

- [ ] Commit the `.age` files:
  ```bash
  git add secrets/*.age secrets/secrets.nix
  git commit -m "add encrypted secrets"
  ```

---

## Phase 1 — Server installation

### 1a. Boot NixOS installer (x86_64)

Download [NixOS minimal ISO](https://nixos.org/download), boot from USB.

**To SSH into the installer from your workstation** (recommended — easier to
copy/paste commands):

On the installer console:
```bash
# Set a password for the nixos user
passwd
# Enter any password you like — it's temporary and only used for this session.

# Find the machine's IP
ip addr show
```

Then from your workstation:
```bash
ssh nixos@<ip>
```

### 1b. Partition and encrypt the server disk

```bash
# Identify your disk
lsblk

# Partition (adjust /dev/nvme0n1 to your disk)
parted /dev/nvme0n1 -- mklabel gpt
parted /dev/nvme0n1 -- mkpart ESP fat32 1MiB 512MiB
parted /dev/nvme0n1 -- set 1 esp on
parted /dev/nvme0n1 -- mkpart primary 512MiB 100%

# Format EFI
mkfs.fat -F 32 -n BOOT /dev/nvme0n1p1

# Encrypt root partition
cryptsetup luksFormat --type luks2 /dev/nvme0n1p2
# ↑ Enter the passphrase you will type at every boot.
cryptsetup luksOpen /dev/nvme0n1p2 cryptroot

# Format root
mkfs.ext4 -L nixos /dev/mapper/cryptroot

# Mount
mount /dev/mapper/cryptroot /mnt
mkdir -p /mnt/boot
mount /dev/nvme0n1p1 /mnt/boot

# Note the UUIDs — you will need them in the next step.
blkid /dev/nvme0n1p2  # → LUKS UUID  (goes in hosts/server/default.nix)
blkid /dev/nvme0n1p1  # → EFI UUID   (goes in hosts/server/hardware-configuration.nix)
```

### 1c. Generate hardware config and update the repo

```bash
# On the installer:
nixos-generate-config --root /mnt
cat /mnt/etc/nixos/hardware-configuration.nix
```

On your workstation, update the repo with the hardware specifics:
- Replace `hosts/server/hardware-configuration.nix` with the generated output.
- Set the LUKS UUID in `hosts/server/default.nix`:
  ```nix
  boot.initrd.luks.devices."cryptroot".device =
    "/dev/disk/by-uuid/<LUKS_UUID>";
  ```
- Commit and push (or make the repo available to the installer via USB/network).

### 1d. Install NixOS on the server

The repo is only needed on the installer for this one-time `nixos-install`.
After first boot, all subsequent deployments are done from your workstation
with `nixos-rebuild switch --target-host` — the repo never needs to live on
the server itself.

Get the repo onto the installer (pick one):
```bash
# Option A — clone from your git remote (if the installer has internet access):
nix-shell -p git --run "git clone <your-repo-url> /mnt/etc/nixos/repo"

# Option B — copy from a USB stick:
cp -r /media/usb/nixos /mnt/etc/nixos/repo
```

Then install:
```bash
nixos-install --flake /mnt/etc/nixos/repo#server --impure
```

### 1e. First boot

- Type the LUKS passphrase at the boot prompt.
- SSH in as `admin`.
- Verify services: `systemctl status caddy authentik postgresql redis-authentik`
- Wait for Caddy to generate the CA cert (usually 10-30 seconds after start).
- Check Tang is running: `systemctl status tang`
- Get Tang's advertise URL: `curl http://localhost:7500/adv`

---

## Phase 2 — Pi installation

### 2a. Flash NixOS installer to SD card (on your workstation)

Download the NixOS AArch64 SD image and flash it to the Pi's microSD card:

```bash
# Download the aarch64 SD image from https://nixos.org/download (look for
# "NixOS 24.11 ... aarch64 ... SD image")
# Then flash it (replace /dev/sdX with your SD card device — check with lsblk):
zstdcat nixos-sd-image-*.img.zst | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

Insert the SD card into the Pi 5. The Pi will boot from it.

### 2b. Boot NixOS AArch64 installer on Pi 5

Connect the Pi to your network and power it on.

If SSH asks for a password, set one first on the Pi console:
```bash
passwd   # set any temporary password
ip addr show  # note the IP
```

Then from your workstation:
```bash
ssh nixos@<pi-ip>
```

### 2c. Partition and format storage drives

> **IMPORTANT**: The Pi boots from microSD/USB. The two 4 TB drives are separate.

```bash
# Identify the drives (NOT the boot media)
lsblk

# Get the stable by-id paths for both drives (use these — not /dev/sdX):
ls -la /dev/disk/by-id/ | grep -v part | grep -v mmc

# Encrypt and format Drive A
cryptsetup luksFormat --type luks2 /dev/disk/by-id/DRIVE_A_ID
cryptsetup luksOpen /dev/disk/by-id/DRIVE_A_ID storage-a
mkfs.xfs -L storage-a /dev/mapper/storage-a

# Encrypt and format Drive B
cryptsetup luksFormat --type luks2 /dev/disk/by-id/DRIVE_B_ID
cryptsetup luksOpen /dev/disk/by-id/DRIVE_B_ID storage-b
mkfs.xfs -L storage-b /dev/mapper/storage-b
```

Now update the repo on your workstation with the actual drive paths:
- `modules/pi/clevis-unlock.nix` — replace both `CHANGE_ME_DRIVE_A` / `CHANGE_ME_DRIVE_B`
- `hosts/pi/services/storage.nix` — replace both `CHANGE_ME_DRIVE_A` / `CHANGE_ME_DRIVE_B`

Commit and push (or make available to the Pi installer).

### 2d. Bind Clevis to Tang

```bash
# Pi must be able to reach the server on port 7500.
# Verify: curl http://SERVER_IP:7500/adv

# Bind Drive A
clevis luks bind -d /dev/disk/by-id/DRIVE_A_ID tang \
  '{"url":"http://SERVER_IP:7500"}' -y

# Bind Drive B
clevis luks bind -d /dev/disk/by-id/DRIVE_B_ID tang \
  '{"url":"http://SERVER_IP:7500"}' -y

# Test unlock:
clevis luks unlock -d /dev/disk/by-id/DRIVE_A_ID -n storage-a
```

### 2e. Generate Pi hardware config and update the repo

```bash
# On the installer:
cat /etc/nixos/hardware-configuration.nix
```

Replace `hosts/pi/hardware-configuration.nix` in the repo with the output.
Commit and push (or make available to the Pi installer).

### 2f. Install NixOS on the Pi

Same as the server: the repo is only needed here for the one-time install.

Get the repo onto the installer (pick one):
```bash
# Option A — clone from your git remote (if the installer has internet access):
nix-shell -p git --run "git clone <your-repo-url> /tmp/repo"

# Option B — copy from USB:
cp -r /media/usb/nixos /tmp/repo
```

Then install:
```bash
nixos-install --flake /tmp/repo#pi --impure
```

### 2g. First Pi boot

- Pi should auto-unlock drives via Clevis/Tang (server must be running).
- Verify: `lsblk` should show storage-a and storage-b as open mappers.
- Verify NFS: `showmount -e localhost`
- Verify Snapclient: `systemctl status snapclient`
- TV launcher should appear on HDMI (if monitor attached).

### 2h. Clone the config repo on each machine

Unattended upgrades rebuild from a local copy of this repo at `/etc/nixos`.
Clone it on both machines now:

```bash
# On the server
ssh admin@server
sudo git clone <your-repo-url> /etc/nixos
sudo cp /path/to/local.nix /etc/nixos/local.nix   # copy your local settings

# On the Pi
ssh admin@pi5
sudo git clone <your-repo-url> /etc/nixos
sudo cp /path/to/local.nix /etc/nixos/local.nix
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

### 3a. Re-key agenix secrets with host SSH keys

Now that both machines are running, collect their SSH host keys and re-encrypt
all secrets so hosts can decrypt them at activation time:

```bash
# Get host keys
ssh admin@server cat /etc/ssh/ssh_host_ed25519_key.pub
ssh admin@pi5    cat /etc/ssh/ssh_host_ed25519_key.pub

# Add both keys to secrets/secrets.nix → server and pi variables.
# Then re-encrypt all secrets for all recipients:
cd secrets
agenix -r

# Rebuild both hosts so they pick up the re-keyed secrets:
nixos-rebuild switch --flake .#server --target-host admin@server --impure
nixos-rebuild switch --flake .#pi     --target-host admin@pi5    --impure
```

### 3b. Authentik initial setup

Visit `https://auth.<domain>/if/flow/initial-setup/` and create the initial admin account.

#### OIDC providers (native SSO)

For each service below, go to **Applications → Providers → Create → OAuth2/OpenID Provider**:
set Client type to `Confidential`, Signing Key to `authentik Self-signed Certificate`,
scopes to `openid email profile`. Then create an **Application** linked to that provider.

| Service | Redirect URI |
|---|---|
| Home Assistant | `https://ha.<domain>/auth/oidc/callback` |
| Nextcloud | `https://cloud.<domain>/apps/user_oidc/code` |
| Immich | `https://photos.<domain>/auth/login` and `app.immich:/` |
| Jellyfin (optional) | `https://media.<domain>/sso/OID/redirect/authentik` |
| Grafana | `https://grafana.<domain>/login/generic_oauth` |

After creating each provider, update the corresponding secret and follow the
per-service UI steps below:

```bash
cd secrets
agenix -e nextcloud-oidc-env.age   # NEXTCLOUD_OIDC_CLIENT_ID + _SECRET
agenix -e immich-oidc-env.age      # IMMICH_OAUTH_CLIENT_ID + _SECRET
agenix -e grafana-env.age          # update GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET
```
Also set `CHANGE_ME_GRAFANA_OIDC_CLIENT_ID` in `hosts/server/services/grafana.nix`.

Rebuild to apply the updated secrets:
```bash
nixos-rebuild switch --flake .#server --target-host admin@server --impure
```

**Nextcloud** — enable the OIDC app and connect it to Authentik:
1. Log in to `https://cloud.<domain>` as the local `admin`.
2. Apps → Search "OpenID Connect user backend" → Enable.
3. Settings → OpenID Connect → Add provider:
   - Identifier: `authentik`
   - Client ID / Secret: from `nextcloud-oidc-env.age`
   - Discovery endpoint: `https://auth.<domain>/application/o/<app-slug>/.well-known/openid-configuration`

**Immich** — enable OAuth in Immich settings:
1. Log in to `https://photos.<domain>` as the local admin.
2. Administration → Settings → OAuth → Enable OAuth.
3. Fill in Issuer URL, Client ID, Client Secret from `immich-oidc-env.age`.
   Issuer URL: `https://auth.<domain>/application/o/<app-slug>/`

**Home Assistant** — configure OIDC via the UI:
1. Log in to `https://ha.<domain>`.
2. Settings → People → Add Auth Provider → OpenID Connect.
3. Fill in Client ID/Secret from the Authentik application.
   Discovery URL: `https://auth.<domain>/application/o/<app-slug>/.well-known/openid-configuration`

**Jellyfin** (optional) — requires the SSO plugin:
1. Log in to `https://media.<domain>` as admin.
2. Dashboard → Plugins → Catalog → SSO-Auth → Install. Restart Jellyfin.
3. Dashboard → SSO-Auth → Add provider:
   - OID Endpoint: `https://auth.<domain>/application/o/<app-slug>/`
   - Client ID/Secret from the Authentik application.

#### Forward-auth providers (Caddy proxy)

For each service below, go to **Applications → Providers → Create → Proxy Provider**,
choose **Forward auth (single application)**, set the external host, then create an Application.

| Service | External host |
|---|---|
| Frigate | `https://nvr.<domain>` |
| qBittorrent | `https://torrent.<domain>` |
| Bitmagnet | `https://bitmagnet.<domain>` |
| Snapcast | `https://audio.<domain>` |
| Syncthing | `https://sync.<domain>` |

After creating all proxy providers:
1. Go to **Applications → Outposts**.
2. Edit the **embedded-outpost**.
3. Add all five proxy applications to its list and save.

The embedded outpost (built into the `authentik-server` container) activates within seconds.
No rebuild required.

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

Edit `/var/lib/frigate/config/frigate.yml` on the server (or update
`hosts/server/services/frigate.nix` and rebuild).
Replace `EXAMPLE_CAMERA_NAME` and camera RTSP URLs.

### 3g. Set up rclone for Frigate cloud sync

Decrypt and edit the rclone config:
```bash
agenix -d secrets/rclone-frigate-config.age > /tmp/rclone.conf
# Edit /tmp/rclone.conf with your cloud storage credentials.
agenix -e secrets/rclone-frigate-config.age < /tmp/rclone.conf
rm /tmp/rclone.conf
```

Update `EXAMPLE_BUCKET` in `hosts/server/services/frigate.nix`.

### 3h. Grafana initial setup

All secrets were created in Phase 0c. After setting the Authentik OIDC client secret
in `grafana-env.age` and the client ID in `grafana.nix` (covered in step 3b):

```bash
nixos-rebuild switch --flake .#server --target-host admin@server --impure
```

Visit `https://grafana.<domain>` — the InfluxDB datasource is provisioned
automatically. Log in with Authentik or the local `admin` break-glass account.

### 3i. Telegraf token setup

Telegraf needs a write-only InfluxDB token (separate from the operator token
used by Grafana).

1. Log into InfluxDB at `http://<server-ip>:8086` (not exposed via Caddy —
   use the server IP directly or an SSH tunnel).
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
   nixos-rebuild switch --flake .#server --target-host admin@server --impure
   nixos-rebuild switch --flake .#pi     --target-host admin@pi5    --impure
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
   If you add a folder on Pi storage Drive A instead, update `syncthing.nix` to set
   `lanbat.nfsDependentServices."syncthing" = [ "a" ]` (or both).

### 3l. Wyoming voice assistant

> **Hardware required:** a USB microphone (or microphone HAT) and speaker
> connected to the Pi.

1. Verify all four Wyoming services are running on the server:
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
   `microphone.command` in `hosts/pi/services/wyoming-satellite.nix`.

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
`hosts/server/services/snapcast.nix` for examples (MPD, librespot, shairport-sync).

Until a source is connected, the pipe is silent but Snapclient on the Pi will
connect and wait. Verify the client is connected at `https://audio.<domain>`.

---

## Phase 4 — Ongoing

- Backup the Tang key directory: `rsync -a /var/lib/tang/ BACKUP_LOCATION/`
- Test Pi unlock after server reboot to verify Clevis/Tang works.
- Pin container image versions when stability matters.
- Run `nixos-rebuild switch --flake .#server --impure` / `.#pi --impure` to deploy changes.
