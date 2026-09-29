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
their marker says already done, and re-applies the home screen even if it already
matches `homeActivity`.

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

## Default home screen

Setting `homeActivity` makes an installed app the box's default launcher — useful for a
box dedicated to a single app such as Argosy (see "RomM through Argosy" below):

```nix
androidDevices.bedroom.homeActivity = "com.nendo.argosy/.MainActivity";
```

The value is `package/activity`; a leading `.` on the activity (as Android manifests
commonly write it) resolves against the package. The `home` resource runs after `apks`
— the launcher has to be installed before it can be made the default — and does three
things: reads the box's current home activity (`cmd package resolve-activity --brief -a
android.intent.action.MAIN -c android.intent.category.HOME`), calls `cmd package
set-home-activity <component>` only if that differs from what's wanted, then **reads it
back** to confirm the change stuck. A box that refuses (some vendor skins ignore
`set-home-activity` outright, or only accept the change from the on-screen launcher
picker) reports `failed` with `adb`'s reply — never a silent no-op, and never `ok` for a
change that didn't actually take.

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

F-Droid moves a superseded APK from `/repo/` to `/archive/` once an app publishes a new
version, so a pinned `/repo/` URL in the lockfile 404s at that point — with no warning
and no relation to anything you changed. The symptom is an opaque `fetchurl` 404 on
*any* rebuild of a host that enables this plugin, F-Droid apps and all, not just the one
that moved. The fix is the same either way: `nix run .#android-update` to re-resolve the
pinned URLs, then commit the regenerated lockfile.

## Snapshots and restoring after a reset

Every device also gets an `android-capture-<name>` oneshot unit — not started
automatically, only ever on request:

```bash
systemctl start android-capture-bedroom
```

It takes a **read-only** snapshot: every user-installed package with its version and
installer (`pm list packages -3 -i --show-versioncode`), every `settings list
global|secure|system` key and value, the current home activity, and the device facts
(model, SDK, ABI) `adb` already reports on connect. The snapshot is written to
`/var/lib/android-provision/<name>/snapshots/<UTC timestamp>.json`, mode `0600` in a
mode `0700` directory, and it **never enters the repository**: settings values include
things like the device's Bluetooth address and Wi-Fi network name, which have no
business in a public git history. Keep snapshots on the server's disk (or copy them
somewhere private) — don't `git add` them.

### The app report

Right after a capture, it prints a proposed source for every installed app, as a
ready-to-paste fragment for `androidDevices.<box>`:

- already pinned in the lockfile (as a `packages` or `github` entry) — reused as-is;
- found in F-Droid's index but not yet pinned — added under `packages` with a comment
  that it still needs `nix run .#android-update`;
- installed by the Play Store (`com.android.vending`) — printed as a comment, for
  reinstalling by hand and signing in;
- anything else — printed as "no known source", meaning it needs a GitHub repo or an
  Obtainium URL added by hand.

`capture --no-fdroid` skips the F-Droid index lookup (the report then treats an unlocked
app as unknown rather than checking F-Droid); `capture --lockfile PATH` reports against
a lockfile other than the one built into the package.

### Comparing two snapshots

`android-provision diff OLD NEW [--ignore NS/KEY]` compares two snapshot files and
prints, per settings namespace, every key that changed (`old -> new`), apps that
appeared or disappeared, an app whose version changed, any home-activity change, and —
last — a ready-to-paste

```nix
settings = { ... };
homeActivity = "...";
```

fragment holding the *old* value of every setting that differs (the values to restore).
A setting whose old value is the literal string `"null"` is listed as changed but never
put in the restore fragment as a value — `settings put ... null` would store that literal
string, not leave the key unset — so it appears there as a one-line comment instead.
`capture --diff OLD [--ignore NS/KEY]` runs the same comparison, with the same
`--ignore`, between `OLD` and the snapshot the capture just took, so a single command
can both snapshot a freshly reset box and show what the reset changed.

A handful of keys change by themselves or identify one installation — boot counters,
setup-wizard flags, the Bluetooth address, `secure/android_id` — and restoring them is
meaningless. `diff.VOLATILE` lists them with a one-line reason each; `--ignore NS/KEY`
(repeatable) adds more without touching the code, for anything volatile a real device
turns up that the built-in list doesn't cover yet.

### The reset runbook

To learn exactly what a factory reset costs a given box, and turn that into
`androidDevices.<box>` configuration:

1. Before touching the box, take a baseline: `systemctl start android-capture-<box>`.
2. Factory-reset the box. Re-enable network ADB and accept the "Allow USB debugging?"
   dialog again — this manual step is irreducible; nothing on the server side can do it
   for you.
3. Snapshot the fresh box and diff it against the baseline:
   `android-provision capture --manifest ... --out-dir ... --diff <baseline>` (or
   `capture` then `diff <baseline> <fresh>` as two steps). Copy the settings, apps and
   home activity the diff prints into `androidDevices.<box>`, and extend the ignore list
   with anything that turns out to be volatile.
4. Deploy and provision the box, then diff the live box against the baseline again
   (`diff <baseline> <live-snapshot>`, or `capture --diff <baseline>` once more). What's
   left in that diff is what a reset really costs on top of provisioning — record it in
   this document.

Beyond that runbook, the manual steps a reset can never avoid are: enable network ADB
and accept the ADB prompt, pair Argosy with one code (see below), and sign in to Play
Store apps. Everything else — apps, changed settings, the home screen, the internal CA
— comes back from one run of the box's provisioning unit.

## RomM through Argosy

[Argosy Launcher](https://github.com/rommapp/argosy-launcher) is a RomM client for
Android TV: it lists the RomM library, downloads a game on demand, launches it, and
syncs its save back to RomM. Getting it onto a box is ordinary `androidDevices`
configuration, not a special case:

```nix
androidDevices.bedroom = {
  github = [
    { repo = "rommapp/argosy-launcher"; asset = "argosy-v*-arm64.apk"; }
  ];
  homeActivity = "com.nendo.argosy/.MainActivity";
  # caCerts left at its default: the internal CA, so Argosy trusts RomM's TLS.
};
```

The pinned asset glob (`argosy-v*-arm64.apk`) matches Argosy's `arm64-v8a` release only
— this module pins one APK per device `abi`, not a set of variants for every ABI a
release publishes. One repo pins exactly one lockfile entry: `update.resolve_github`
keys its result by repo, `write_lockfile` builds `{ key: entry }`, and the module looks
up `lock.${g.repo}` — a second `github` entry for the same repo would just replace this
one, not add an arm32 variant alongside it. A box with a different ABI, or a deployment
mixing arm64 and arm32 boxes, should pin the release's universal asset instead: Argosy
ships `argosy-v<version>.apk` (no ABI suffix) alongside the per-ABI ones, and the glob
`argosy-v*.[0-9].apk` matches only that universal asset, not `argosy-v2.18.0-arm32.apk`
or `argosy-v2.18.0-arm64.apk`. `apk_metadata` then reads every ABI the universal APK
actually contains, so the resulting lockfile entry works for any device `abi`. Keep the
`arm64-v8a`-only pin above when every box is arm64 — it's a smaller download.

Setting `homeActivity` to Argosy's launch activity makes it the box's default home
screen, so the box boots straight into the game library. `caCerts` at its default
installs the internal CA Caddy issues from into the user trust store — Argosy is one of
the apps that opts into trusting user CAs, so it can reach `romm.<domain>` over the
deployment's own TLS without a browser-only workaround.

Pairing is the one step this module can't do for you: on the box, open Argosy and
generate (or scan) a pairing code; enter that code in RomM to link the two. RomM's move
to its own login plus Authentik OIDC (so a browser sign-in gates the web UI) is tracked
separately and isn't part of what this branch changes — from the box's point of view,
Argosy talks to RomM's API with its own paired session regardless of how a browser signs
into RomM.

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
| `homeActivity` | `null` | Activity to make the default home screen, as `package/activity`. Set after the apps are installed; a box that refuses is reported `failed`. |
| `deviceOwner.enable` | `false` | Set a Device Owner via `dpm set-device-owner`. Only succeeds on a box with no configured accounts. |
| `deviceOwner.component` | `null` | DPC admin receiver component, e.g. `"com.example.dpc/.AdminReceiver"`. Required when `deviceOwner.enable` is set. |

Evaluation rejects two devices sharing a `host:port`, `deviceOwner.enable` without a
`deviceOwner.component`, a `homeActivity` that isn't of the form `package/activity`, and
any `packages`/`github` entry missing from `apks.lock.json` (with a pointer to
`nix run .#android-update`) or lacking an APK variant for the device's `abi`.

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
