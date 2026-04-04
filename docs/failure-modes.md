# Failure Modes and Recovery

## Normal boot (server then Pi)

1. Server boots. Host layer comes up immediately — SSH reachable, both LUKS layers locked.
2. Always-on services start automatically: Caddy, PostgreSQL, Authentik, HA, Grafana,
   InfluxDB, Mosquitto, Frigate, Snapcast, Wyoming, SearXNG, Telegraf.
3. Admin SSHes in and runs `sudo unlock-control` → Tang starts on port 7500.
4. Admin runs `sudo unlock-workload` → Nextcloud, Immich, Jellyfin, Vaultwarden,
   Syncthing, Samba, qBittorrent, Bitmagnet come up.
5. Pi boots from SD card. After network is up, `storage-a-unlock` and `storage-b-unlock`
   contact Tang, unlock both NVMe drives (retries every 5 min until Tang is reachable).
6. `/mnt/storage-a` and `/mnt/storage-b` mount on the Pi. NFS server starts.
7. Server automounts `/srv/storage/a` and `/srv/storage/b` on first access.
8. NFS-dependent services (Jellyfin, qBittorrent, Frigate, Samba) fully operational.

Steps 1–2 are automatic. Steps 3–4 require a single SSH session after reboot.
Use `sudo unlock-all` to run both in sequence.

---

## Server boots before Pi

Server comes up. NFS mounts have `noauto` + automount — they mount lazily on first access.

If Jellyfin/qBittorrent/Frigate/Samba try to start before the Pi is available:
- The automount unit is triggered.
- It waits for the NFS connection (up to `x-systemd.mount-timeout=30`).
- If Pi is not up yet, the mount fails.
- Services that `bindsTo` the mount are **stopped** (not left in a broken state).
- Systemd will retry the mount unit when NFS automount is triggered again.

Once the Pi comes up and NFS becomes available:
- The automount unit succeeds.
- systemd restarts `jellyfin`, `podman-qbittorrent`, `podman-frigate`, `samba` automatically (Restart=on-failure + RestartSec=15s).

**You do not need to do anything.** This is handled entirely by systemd.

---

## Pi boots before server

1. Pi boots from SD card. Always-on Pi services come up normally.
2. `storage-a-unlock` and `storage-b-unlock` attempt Clevis unlock — Tang is not
   reachable → both services fail and schedule a retry in 5 minutes.
3. Drives stay **encrypted and locked**. NFS server starts but exports empty paths.
4. Server eventually comes up. Admin runs `unlock-control` → Tang starts.
5. On the next retry (within 5 minutes), the Pi's unlock services succeed automatically.
6. Drives mount. NFS becomes available. Server NFS-dependent services restart.

**No manual intervention needed** — the Pi retries automatically until Tang is reachable.

If you want to trigger unlock immediately without waiting for the retry:
```bash
ssh admin@pi
sudo systemctl restart storage-a-unlock.service storage-b-unlock.service
```

Fallback passphrase (if Clevis binding is lost or Tang is permanently unavailable):
```bash
ssh admin@pi
sudo cryptsetup luksOpen /dev/disk/by-id/DRIVE_A_ID storage-a
sudo mount /dev/mapper/storage-a /mnt/storage-a
sudo cryptsetup luksOpen /dev/disk/by-id/DRIVE_B_ID storage-b
sudo mount /dev/mapper/storage-b /mnt/storage-b
```

---

## Pi reboots while server services are running

1. Pi reboots → NFS connection drops.
2. Server's NFS mounts stall → become unavailable.
3. systemd detects mount units failed (soft NFS timeout ~90s).
4. Services bound to those mounts (`bindsTo`) are **stopped** by systemd.
5. Pi reboots, unlocks drives via Clevis, NFS comes back.
6. Server automount unit remounts `/srv/storage/a` and `/srv/storage/b`.
7. Bound services restart automatically (Restart=on-failure).

**Expected total outage for NFS-dependent services: Pi reboot time + ~30s.**
Usually 2-3 minutes total.

Services that stay up during Pi reboot (always-on tier):
- Caddy ✓
- PostgreSQL ✓
- Authentik ✓
- Home Assistant ✓
- Grafana ✓
- InfluxDB ✓
- Mosquitto ✓
- Frigate ✓ (local DB; live stream from cameras unaffected)
- SearXNG ✓
- Snapserver ✓
- Wyoming pipeline (STT/TTS/wake word) ✓
- Telegraf (server) ✓
- Redis (Immich) ✓
- Homepage ✓

Workload-gated services that pause and restart (NFS-dependent):
- Jellyfin ⏸→▶
- qBittorrent ⏸→▶
- Frigate ⏸→▶
- Samba ⏸→▶
- Immich server ⏸→▶ (only the storage-facing parts)
- Syncthing ⏸→▶ (synced folder is on Drive B)

Note: the Wyoming satellite on the Pi also goes down during a Pi reboot, so
voice assistant commands will be unavailable until the Pi is back up.
The server-side Wyoming pipeline (STT/TTS/wake word) stays running throughout.

Pi Telegraf also goes down during a Pi reboot, causing a gap in Pi metrics.
Server metrics continue uninterrupted.

---

## NFS mount timeout and "soft" behaviour

We use `soft` NFS mounts with `timeo=30,retrans=3` (~90 second total timeout).
After the timeout, the kernel returns `EIO` to any process reading from the mount.

Without our `bindsTo` dependency, processes would receive I/O errors and possibly
write corrupt state. With `bindsTo`, the service is stopped cleanly before that
happens — this is the safe failure model.

**Do not change soft mounts to hard mounts** without also removing the `bindsTo`
dependencies. Hard mounts will block forever and prevent services from stopping.

---

## Unattended upgrade reboot (Pi)

The Pi reboots automatically after an upgrade if a new kernel is activated
(between 04:00–06:00).  This follows the same path as a normal Pi reboot:
NFS-dependent services on the server briefly pause and auto-restart.

The server is **never** rebooted automatically.  A "reboot pending" state
means a new kernel is available but the running kernel is the previous one —
this is harmless until the next manual maintenance window.

---

## What needs manual intervention

| Situation | Manual action needed? |
|---|---|
| Server LUKS at boot | Yes — SSH in, run `unlock-control` then `unlock-workload` |
| Pi boots before server | No — Pi retries every 5 min until Tang is reachable |
| Normal Pi reboot | No |
| Normal server reboot | Yes — SSH in, run `unlock-all` |
| Server NIC failure | No (Pi retries) |
| Tang key rotation | Yes — re-bind Clevis on Pi |
| Drives fill up | Yes — cleanup or expand |
| NixOS package upgrades | No — auto-upgrade runs nightly |
| Server new kernel | Yes — manual reboot required (LUKS prompt) |
| Pi new kernel | No — Pi reboots automatically via Clevis/Tang |
| Container image updates | Manual `nixos-rebuild switch` |

---

## qBittorrent and active torrents on Pi reboot

qBittorrent is stopped by systemd when the NFS mount disappears.
qBittorrent saves resume data to disk periodically (default: every 30-60 seconds).
When it restarts, it reads resume data from `/var/lib/qbittorrent` (server-local).
Torrents resume from where they were; partial downloads on NFS are intact.

**Worst case**: up to 60 seconds of torrent data may need to be re-downloaded.
No torrent data is permanently lost because the files are on NFS (Pi drives),
which never had a write error — NFS just became unavailable.
