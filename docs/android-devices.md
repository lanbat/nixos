# Android device provisioning

`androidDevices` declaratively provisions Android TV boxes over ADB from the server:
pinned APKs, an internal CA certificate, an Obtainium tracking list and `settings put`
values, converged by a systemd oneshot unit per box. Nothing runs on a timer — a box is
touched only when you ask, never while someone is watching TV on it.

## Limitations, before anything else

Android's platform model — not this tool — sets these limits. They were verified
against the reference device (a Homatics Box R 4K Plus, Android 14 / SDK 34, unrooted
user build) and hold for any similar unrooted box.

| Limit | Consequence |
|---|---|
| Since Android 7, apps ignore user-installed CAs unless they opt in | Installing the internal CA fixes the **browser**. It does **not** fix Kodi, Jellyfin or YouTube. |
| No `adb` command installs a CA silently on an unrooted user build | One on-screen "Install this certificate?" confirmation per box, every time the CA changes. |
| The trust store (`/data/misc/user/0/cacerts-added/`) can't be read without root | CA and Obtainium idempotency is **marker-backed** — a file the tool wrote to `/sdcard/.lanbat-provision/` last time, not proof the device still agrees. `provision --force` re-applies regardless of the marker. |
| Google Play-only apps can't be provisioned by any of the three sources (F-Droid, GitHub releases, Obtainium) | Roughly 10 of the 24 apps on the reference box (Stremio, Twitch, Castify, Projectivy Launcher, Nova BG among them). Unsupported by design, not a bug — put these on Obtainium's list if it can track them, or install them by hand. |
| The reference box has no DocumentsUI | Every Storage Access Framework file picker fails, so Obtainium's file-based list import doesn't work either. The provisioner pushes the URL list to `/sdcard/Download/` and prints it; you paste it into Obtainium's "Import from URL list" text field by hand. |
| Device Owner mode requires a box with **no configured accounts** | In practice, a factory reset per box. The tool will never perform one for you — `deviceOwner.enable` only calls `dpm set-device-owner` and reports `failed` with the reason if an account is already configured. |
| Split APKs (Android App Bundle install sets) aren't supported | `adb install` takes exactly one file. A GitHub release that publishes a base APK plus config splits either fails to resolve during `android-update` (the asset glob matches more than one file) or, if narrowed to one file, fails to install on the device and is reported `failed`, not silently skipped. |
| The module never uninstalls anything | Removing an app from `packages`/`github`/`obtainium` removes nothing from the device. Uninstall it on the box yourself. |

If a limitation here is a dealbreaker for an app, that app belongs on Obtainium's list
(if it can update it) or stays a manual install — not a fight with this tool.

## Quickstart

Enable the plugin on the server host and declare a device:

```nix
# deployments/homelab/deploy.nix
hosts.server.plugins = [
  inputs.self.lanbatPlugins.services
  inputs.self.lanbatPlugins.android
];

deployment.androidDevices = {
  bedroom = {
    host = "192.0.2.50"; # ADB over TCP must already be enabled on the box
    packages = [ "de.badaix.snapcast" ];
  };
};
```

`lanbatPlugins.android` configures nothing when `androidDevices` is empty, so it's safe
to enable on every server even before the first box is declared.

## One-time ADB authorization

Before the server can reach a box, do this once per box:

1. On the box, enable **ADB over TCP** (Settings → Device Preferences → Developer
   options → Network debugging, wording varies by vendor skin) so `adbd` listens on
   port 5555.
2. Run the provisioning unit once: `systemctl start android-provision-bedroom`.
3. The box shows an on-screen **"Allow USB debugging?"** dialog. Accept it with
   **always allow**.

`adb`'s client key lives at `/var/lib/android-provision/.android/adbkey` (the unit sets
`HOME=/var/lib/android-provision` so `adb` creates and reuses the key there) and is
**never rotated**. That's deliberate: a key regenerated per run would re-trigger the
dialog on the TV every single time. Losing that key file (state directory deleted,
reinstall) means re-accepting the dialog on every box once.

## Running it

Three ways to run a device's manifest, all equivalent up to whether they touch the box
and where the manifest comes from:

```bash
systemctl start android-provision-bedroom         # converge the device
systemctl start android-provision-bedroom-plan     # dry run: connects, reports, changes nothing
nix run .#android-provision -- provision --manifest <path>  # run a manifest directly
```

The `-plan` unit runs the same reconciliation with `apply=false`: it still connects to
the box and reads its state, but every resource that would change reports `changed`
with a "would ..." reason instead of touching anything. Use it before `provision` on a
box you don't want to risk mid-show.

`nix run .#android-provision` is the raw CLI — useful for testing a hand-written
manifest or scripting outside the NixOS units. `provision` also accepts `--force`,
which re-applies the marker-backed resources (CA certs, Obtainium's URL list) even if
their marker says already done.

### Outcomes

Every resource (an APK, a setting, the CA cert, the Obtainium list, the device owner)
reports one of four outcomes, printed as `<status> <resource>/<target> -- <reason>`:

| Status | Meaning |
|---|---|
| `ok` | Already matches the manifest; nothing to do. |
| `changed` | Applied (or, under `plan`, would be applied). |
| `skipped` | Deliberately not applied, with a reason — e.g. `minSdk` too high for the device, or a newer version is already installed and `allowDowngrade` is unset. `skipped` exists so an unsupported or unverifiable situation is reported honestly instead of a false `ok`. |
| `failed` | Attempted and did not work, with a reason. |

One resource failing never aborts the run: every independent resource still converges,
and the process exit code reports the failure at the end (see Exit codes below).

## Updating apps

APK sources are pinned in `pkgs/android-provision/apks.lock.json`, resolved once by a
network-touching update step so that evaluating the flake stays pure and a provision
run never depends on F-Droid or GitHub being reachable. Never hand-edit the lockfile.

```bash
nix run .#android-update -- "" \
  --fdroid de.badaix.snapcast \
  --github theothernt/AerialViews=*.apk
```

Review the diff (`git diff pkgs/android-provision/apks.lock.json`) before committing —
`android-update` **replaces the entire lockfile** with only the packages and GitHub
repos you pass it that run. Omit an app you meant to keep and the diff will show it
disappearing; that's your signal to add it back to the command, not evidence of a bug.
The empty first argument selects the default lockfile path; pass a path there instead
to update a different file.

`GITHUB_TOKEN` in the environment raises the GitHub API rate limit for `--github`
lookups; it isn't required for public repos at low volume.

## Option reference

Every field of `androidDevices.<name>`, with its default:

| Option | Default | Description |
|---|---|---|
| `enable` | `true` | Whether to provision this device. |
| `host` | — (required) | Device address. ADB over TCP must already be enabled on it. |
| `port` | `5555` | ADB over TCP port. |
| `abi` | `"arm64-v8a"` | Device ABI, used to pick an APK variant for apps (like VLC) that publish one APK per ABI. |
| `packages` | `[ ]` | F-Droid package identifiers, pinned by `apks.lock.json`. |
| `github` | `[ ]` | GitHub releases, pinned by `apks.lock.json`. Each entry is `{ repo, asset }`, `asset` a glob matching exactly one release asset (default `"*.apk"`). |
| `obtainium` | `[ ]` | Apps handed to Obtainium as `{ url }` entries. Obtainium owns their updates; the provisioner never installs them itself. |
| `caCerts` | `[ ../../secrets/caddy-ca-root.crt ]` | CA certificates to install into the user trust store. Setting this **replaces** the default rather than adding to it. |
| `settings` | `{ }` | `settings put` values by namespace (`global`, `secure`, `system`), e.g. `{ global.screen_off_timeout = 600000; }`. |
| `allowDowngrade` | `false` | Replace an installed app that is newer than the lockfile's pinned version. |
| `deviceOwner.enable` | `false` | Set a Device Owner via `dpm set-device-owner`. Only succeeds on a box with no configured accounts. |
| `deviceOwner.component` | `null` | DPC admin receiver component, e.g. `"com.example.dpc/.AdminReceiver"`. Required when `deviceOwner.enable` is set. |

Evaluation rejects two devices sharing a `host:port`, `deviceOwner.enable` without a
`deviceOwner.component`, and any `packages`/`github` entry missing from
`apks.lock.json` (with a pointer to `nix run .#android-update`) or lacking an APK
variant for the device's `abi`.

## Snapcast needs no configuration

`de.badaix.snapcast` (Snapdroid) is the one app in the reference inventory that needs
nothing from this module beyond being installed: it self-discovers the server over
mDNS. `services/snapcast.nix` publishes `_snapcast._tcp`/`_snapcast-ctrl._tcp` over
Avahi and binds snapserver to `::` (dual-stack) because Android's mDNS resolver prefers
a host's IPv6 addresses when Avahi publishes them — a v4-only bind gets "connection
refused" from a client that tried the v6 address first. On this deployment Avahi's own
IPv6 publishing is disabled (a setting shared with Samba, see `services/samba.nix`), so
in practice only the LAN IPv4 address goes out over mDNS today; the dual-stack bind is
kept as a defensive measure regardless.

The caveat: a box on a VLAN or Wi-Fi network that blocks multicast will never see the
mDNS advertisement, Snapdroid will find no server, and nothing in this module — or in
`plan`'s output — can detect that from the server side. If a box can't find audio,
check multicast reachability on its network segment before anything else.

## Exit codes

| Code | Constant | Meaning |
|---|---|---|
| 0 | `EXIT_OK` | Every resource is `ok` or `changed`. |
| 1 | `EXIT_RESOURCE_FAILED` | At least one resource reported `failed`. |
| 2 | `EXIT_UNREACHABLE` | The device didn't answer (`adb connect` failed) — check it's powered on and reachable at `host:port`. |
| 3 | `EXIT_UNAUTHORIZED` | The device answered but hasn't authorized this key — accept the on-screen dialog (see One-time ADB authorization). |
| 4 | `EXIT_MANIFEST` | The manifest couldn't be read or parsed, or (for `android-update`) an app identifier couldn't be resolved. |
