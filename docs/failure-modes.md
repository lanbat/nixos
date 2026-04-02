# Failure Modes and Recovery

## Normal boot (server then Pi)

1. Server boots, prompts for LUKS passphrase.
2. After passphrase, all server services start: PostgreSQL, Redis, Caddy, Authentik, HA, etc.
3. Tang starts and is ready on port 7500.
4. Pi boots. initrd brings up the network.
5. Clevis contacts Tang, gets the key material, unlocks both LUKS drives.
6. `/mnt/storage-a` and `/mnt/storage-b` mount.
7. NFS server starts.
8. **Server** automounts `/srv/storage/a` and `/srv/storage/b` on first access.
9. NFS-dependent services (Jellyfin, qBittorrent, Frigate, Samba) start.

Everything comes up automatically. No manual intervention after the server LUKS prompt.

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

1. Pi boots. initrd tries Clevis unlock.
2. Tang is not available → Clevis fails.
3. Drives stay **encrypted and locked**.
4. Pi boots successfully — NFS server starts but exports empty paths.
5. Server eventually comes up. Tang starts.
6. **Pi must be rebooted** (or drives manually unlocked) for drives to become available.

This is the one case that requires manual intervention.

**Recovery:**

Option A — Reboot the Pi (simplest):
```bash
ssh admin@pi5 sudo reboot
# Pi will re-run Clevis during the next boot, which will now succeed.
```

Option B — Manual unlock on the Pi:
```bash
ssh admin@pi5
sudo clevis luks unlock -d /dev/disk/by-id/DRIVE_A_ID -n storage-a
sudo clevis luks unlock -d /dev/disk/by-id/DRIVE_B_ID -n storage-b
sudo systemctl start mnt-storage-a.mount mnt-storage-b.mount
sudo systemctl start nfs-server
```

Option C — Fallback passphrase (if Clevis binding is lost):
```bash
sudo cryptsetup luksOpen /dev/disk/by-id/DRIVE_A_ID storage-a
# Enter the LUKS passphrase set during initial formatting.
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

Services that stay up during Pi reboot:
- Caddy ✓
- Authentik ✓
- Home Assistant ✓
- Homepage ✓
- SearXNG ✓
- MQTT / Mosquitto ✓
- PostgreSQL ✓
- Redis ✓
- Vaultwarden ✓
- Grafana ✓
- InfluxDB ✓
- Snapserver ✓
- Wyoming pipeline (STT/TTS/wake word) ✓
- Telegraf (server) ✓
- InfluxDB ✓
- Grafana ✓

Services that pause and restart:
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

## What needs manual intervention

| Situation | Manual action needed? |
|---|---|
| Server LUKS at boot | Yes — type passphrase |
| Pi boots before server | Yes — reboot Pi after server is up |
| Normal Pi reboot | No |
| Normal server reboot | No (after passphrase) |
| Server NIC failure | No (Pi retries) |
| Tang key rotation | Yes — re-bind Clevis on Pi |
| Drives fill up | Yes — cleanup or expand |
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
