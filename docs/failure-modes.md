# Failure Modes and Recovery

## Normal boot (server then Pi)

1. Server boots. Host layer comes up immediately — SSH reachable, both LUKS layers locked.
2. Always-on services start automatically: Caddy, PostgreSQL (always-on instance),
   Authentik, HA, Grafana, InfluxDB, Mosquitto, Frigate, Music Assistant, Snapcast, Wyoming, SearXNG, Telegraf.
3. Admin SSHes in and runs `sudo unlock-control` → Tang starts on port 7500.
4. Admin runs `sudo unlock-workload` → the PostgreSQL workload instance, Nextcloud, Immich,
   Jellyfin, Vaultwarden, Syncthing, Samba, qBittorrent, Bitmagnet, RomM come up.
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
- PostgreSQL, always-on instance ✓ (the workload instance keeps running too; it doesn't use NFS)
- Authentik ✓
- Home Assistant ✓
- Grafana ✓
- InfluxDB ✓
- Mosquitto ✓
- Frigate ✓ (local DB; live stream from cameras unaffected)
- SearXNG ✓
- Music Assistant ✓ (library scans fail while Pi NFS is down; service stays up)
- Snapserver ✓
- Wyoming pipeline (STT/TTS/wake word) and the server's voice satellite ✓
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
voice commands to it will be unavailable until the Pi is back up.
The server-side Wyoming pipeline (STT/TTS/wake word) and the server's own
satellite stay running throughout.

The conversation agent's LLM (`lanbat.haLlm`) runs outside the homelab. While
it is unreachable, or starting after scaling to zero, commands that Home
Assistant's local intents understand ("turn on the kitchen light") still work;
anything else fails or waits for the endpoint.

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

## Overlay down

This applies only when the profile runs an overlay
(`deployment.overlay.provider` is not `"none"`). With `"none"` there is no
overlay to lose.

**Unaffected, by design:**
- **Tang**, so the storage Pi still unlocks its drives. Tang publishes no
  endpoint and is reached over the LAN.
- **NFS**, so Pi storage and the services that depend on it stay up.
- **Boot.** The overlay interface is not required for `network-online.target`,
  so no host waits for it.
- **Clients.** They reach Caddy over the LAN.

**Breaks:** cross-host service edges whose endpoint transport is `"overlay"`.
In the example layout these are the Pi's Telegraf writing to InfluxDB, and Home
Assistant talking to the storage Pi's voice satellite. Each fails on its own,
and the services themselves keep running. A service with a subdomain placed on
another host than Caddy is one of these edges too: its vhost serves the offline
page until the overlay returns.

**Diagnose:** `networkctl status lanbat0`, and `wg show lanbat0` for the latest
handshakes. The usual causes are a stale `publicKey` in `deploy.nix`, a missing
`secrets/overlay-<host>.age` or one encrypted to the wrong host, and a host with
an `endpoint` that nobody can reach.

**Break-glass:** set `deployment.overlay.provider = "none"` and redeploy. Every
edge goes back to the LAN, together with its generated rules and the addresses
consumers dial. The per-host `overlay` blocks can stay where they are.

---

## What needs manual intervention

| Situation | Manual action needed? |
|---|---|
| Host-root reinstall (disk intact) | No CA redistribution — root is in git/agenix; clients keep trusting the same root |
| Browser TLS warning on homelab sites (e.g. "invalid signature") | Usually yes — **client** stale root in trust store (most common); verify with `openssl verify -CAfile secrets/caddy-ca-root.crt` on the served chain — if OK, fix client trust (`docs/security.md`); if not, server intermediate may be stale (same doc, TLS chain troubleshooting) |
| Server LUKS at boot | Yes — SSH in, run `unlock-control` then `unlock-workload` |
| Pi boots before server | No — Pi retries every 5 min until Tang is reachable |
| Normal Pi reboot | No |
| Normal server reboot | Yes — SSH in, run `unlock-all` |
| Server NIC failure | No (Pi retries) |
| Tang key rotation | Yes — re-bind Clevis on Pi |
| Drives fill up | Yes — cleanup or expand |
| NixOS package upgrades | No — auto-upgrade runs nightly after `git push` |
| Server new kernel | Yes — manual reboot required, then unlock both layers |
| Pi new kernel | No — Pi reboots automatically via Clevis/Tang |
| Container image updates | Yes — bump the tag and deploy |
| Overlay down | No for Tang, NFS and boot; overlay edges pause until it returns, or set `overlay.provider = "none"` and redeploy (see [Overlay down](#overlay-down)) |
| Server root or workload fills up | Yes — grow the volume from LVM free space (`docs/operations.md`) |

---

## qBittorrent and active torrents on Pi reboot

qBittorrent is stopped by systemd when the NFS mount disappears.
qBittorrent saves resume data to disk periodically (default: every 30-60 seconds).
When it restarts, it reads resume data from `/var/lib/qbittorrent` (server-local).
Torrents resume from where they were; partial downloads on NFS are intact.

**Worst case**: up to 60 seconds of torrent data may need to be re-downloaded.
No torrent data is permanently lost because the files are on NFS (Pi drives),
which never had a write error — NFS just became unavailable.
