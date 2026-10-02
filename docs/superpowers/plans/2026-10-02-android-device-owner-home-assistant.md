# Android Device Owner and Home Assistant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Securely install the homelab CA through a minimal Device Owner on compatible Android TV boxes, then provision Home Assistant and a small TV-focused app set.

**Architecture:** Nix builds a profile-specific unsigned DPC containing only the public CA; the server signs it at runtime with agenix-protected deployment keys. The provisioner performs a read-only compatibility preflight, installs and enrolls the DPC, verifies the managed CA through a read-only status broadcast, then reconciles ordinary pinned apps and settings.

**Tech Stack:** Nix/NixOS modules, Python 3 and pytest, Java/Android SDK command-line build tools, ADB, systemd, agenix, F-Droid and GitHub release pinning.

**Spec:** `docs/superpowers/specs/2026-10-02-android-device-owner-home-assistant-design.md`

## Global Constraints

- Device Owner remains opt-in per device and never triggers a factory reset.
- The first implementation rejects headless-system-user mode.
- The DPC package is `org.lanbat.dpc`; its admin component is `org.lanbat.dpc/.LanbatDeviceAdminReceiver`.
- The DPC has no launcher, Internet permission, writable exported control surface, telemetry, or general policy UI.
- Only the public Caddy root certificate enters the APK; its private key remains an existing agenix secret.
- The DPC signing identity is deployment-specific and consists of `android-dpc-keystore` and `android-dpc-keystore-password`.
- Generic external Device Owner components continue to work unchanged.
- Home Assistant uses the stable official `automotive-minimal-release.apk` and requires Android 10/API 29 or later.
- Unsupported firmware or incompatible APKs must be detected before reset as far as a read-only probe permits.
- Existing uncommitted repository changes are not part of this feature and must not be staged by its commits.

## Review Focus

- A TV advertises `android.software.device_admin` but omits or vendor-disables `dpm`: preflight fails without mutation and names the failed capability check; Task 2 pins this.
- A box already has another Device Owner: provisioning names that component and never installs over, removes, or replaces it; Task 3 pins this.
- The locally signed DPC and installed DPC have different signing certificates: provisioning fails before `adb install -r`; Task 3 pins this.
- CA rotation succeeds while unrelated user CAs exist: the DPC removes only its recorded previous CA after verifying the new CA; Task 1 pins this.
- A selected APK exceeds the device SDK or lacks the configured ABI: preflight fails before reset even though ordinary APK reconciliation would only skip it; Task 2 pins this.

---

### Task 1: Minimal Lanbat Android DPC

**Files:**
- Create: `pkgs/android-dpc/default.nix`
- Create: `pkgs/android-dpc/AndroidManifest.xml`
- Create: `pkgs/android-dpc/res/xml/device_admin.xml`
- Create: `pkgs/android-dpc/java/org/lanbat/dpc/CaReconciler.java`
- Create: `pkgs/android-dpc/java/org/lanbat/dpc/AndroidCaStore.java`
- Create: `pkgs/android-dpc/java/org/lanbat/dpc/LanbatDeviceAdminReceiver.java`
- Create: `pkgs/android-dpc/java/org/lanbat/dpc/LifecycleReceiver.java`
- Create: `pkgs/android-dpc/java/org/lanbat/dpc/StatusReceiver.java`
- Create: `pkgs/android-dpc/tests/org/lanbat/dpc/CaReconcilerTest.java`
- Modify: `tests/pkgs-build.nix`

**Interfaces:**
- Consumes: a Nix `caCert` path containing one PEM-encoded root CA.
- Produces: an unsigned, zip-aligned APK at `$out/share/android-dpc/lanbat-dpc-unsigned.apk`; package `org.lanbat.dpc`; component `org.lanbat.dpc/.LanbatDeviceAdminReceiver`; ordered status action `org.lanbat.dpc.STATUS`.
- Status result data: compact JSON with `owner`, lowercase-hex `caSha256`,
  and `installed` fields.

- [ ] **Step 1: Write the pure CA reconciliation test**

Create `CaReconcilerTest.java` with fakes for the policy store and private previous-certificate store. Cover:

```java
public static void main(String[] args) {
    installsDesiredWhenAbsent();
    isIdempotentWhenDesiredIsPresent();
    installsNewBeforeRemovingRecordedOld();
    leavesUnrelatedCertificatesAlone();
    keepsOldWhenNewInstallationFails();
}
```

The rotation assertion must record operations and require exactly:

```java
assertEquals(List.of("install:new", "verify:new", "remove:old", "save:new"), operations);
```

- [ ] **Step 2: Run the Java test to verify it fails**

Run:

```bash
nix build .#checks.x86_64-linux.pkgs-build
```

Expected: FAIL because `pkgs/android-dpc` and `CaReconciler` do not exist.

- [ ] **Step 3: Implement the pure reconciler**

Define focused interfaces in `CaReconciler.java`:

```java
interface CaStore {
    boolean has(byte[] certificate);
    boolean install(byte[] certificate);
    void remove(byte[] certificate);
}

interface PreviousStore {
    byte[] load();
    void save(byte[] certificate);
}

enum Result { INSTALLED, ALREADY_INSTALLED, INSTALL_FAILED, VERIFY_FAILED }

static Result reconcile(byte[] desired, CaStore caStore, PreviousStore previousStore)
```

Install and verify `desired` first. Remove `previous` only when it differs from
`desired` and the desired CA is verified. Never enumerate or remove any other
certificate.

- [ ] **Step 4: Implement Android adapters and lifecycle receivers**

`AndroidCaStore` wraps `DevicePolicyManager` using the fixed admin component.
`LanbatDeviceAdminReceiver.onEnabled`, `LifecycleReceiver` for
`BOOT_COMPLETED` and `MY_PACKAGE_REPLACED` call the same idempotent
reconciliation function.

`StatusReceiver` must:

```java
boolean owner = dpm.isDeviceOwnerApp(context.getPackageName());
boolean installed = owner && dpm.hasCaCertInstalled(admin, desired);
setResultCode(installed ? Activity.RESULT_OK : Activity.RESULT_CANCELED);
setResultData(statusJson(owner, sha256(desired), installed));
```

It is exported only for the read-only ordered broadcast. No exported
component may invoke installation or any other policy mutation.

- [ ] **Step 5: Add the constrained Android manifest**

Declare only:

```xml
<uses-feature android:name="android.software.device_admin" android:required="true"/>
<application android:allowBackup="false" android:usesCleartextTraffic="false">
    <!-- Device admin, boot/package lifecycle, and read-only status receivers -->
</application>
```

Do not request `android.permission.INTERNET`. The admin policy XML contains no
password, wipe, camera, storage-encryption, or keyguard policy declarations.

- [ ] **Step 6: Package the unsigned APK reproducibly**

Use `pkgs.androidenv.composeAndroidPackages` with API/build-tools 35. The
derivation copies `caCert` to `res/raw/lanbat_ca.crt`, compiles Java against
`android.jar`, runs the pure Java test, builds `classes.dex` with `d8`, links
resources with `aapt2`, adds the dex, and runs `zipalign`. It deliberately
does not call `apksigner`.

Expose metadata files beside the APK:

```text
$out/share/android-dpc/package-id
$out/share/android-dpc/component
$out/share/android-dpc/ca-sha256
$out/share/android-dpc/version-code
```

Start at version code 1 and require an explicit increment whenever DPC code or
resources change after the first physical enrollment.

- [ ] **Step 7: Add package smoke assertions**

In `tests/pkgs-build.nix`, build the DPC against
`../secrets/caddy-ca-root.crt`, use `aapt2 dump badging` and `aapt2 dump
permissions`, and assert:

```bash
test -f ${androidDpc}/share/android-dpc/lanbat-dpc-unsigned.apk
test "$(cat ${androidDpc}/share/android-dpc/package-id)" = org.lanbat.dpc
! aapt2 dump permissions "$apk" | rg 'android.permission.INTERNET'
```

- [ ] **Step 8: Run focused checks**

Run:

```bash
nix build -L .#checks.x86_64-linux.pkgs-build
```

Expected: PASS, including the pure rotation test and manifest assertions.

- [ ] **Step 9: Commit**

```bash
git add pkgs/android-dpc tests/pkgs-build.nix
git commit -m "feat: add minimal Android CA device owner"
```

### Task 2: Read-only Device Owner Preflight

**Files:**
- Create: `pkgs/android-provision/src/android_provision/resources/preflight.py`
- Create: `pkgs/android-provision/tests/test_preflight.py`
- Modify: `pkgs/android-provision/src/android_provision/cli.py`
- Modify: `pkgs/android-provision/src/android_provision/manifest.py`
- Modify: `pkgs/android-provision/src/android_provision/adb.py`
- Modify: `pkgs/android-provision/tests/fake_adb.py`
- Modify: `pkgs/android-provision/tests/conftest.py`
- Modify: `pkgs/android-provision/tests/test_manifest.py`
- Modify: `pkgs/android-provision/tests/test_cli.py`

**Interfaces:**
- Consumes: `Manifest.deviceOwner`, `Manifest.apks`, and connected `DeviceInfo`.
- Produces: `preflight.reconcile(adb, info, manifest) -> list[Outcome]`; CLI command `android-provision preflight --manifest PATH`.
- `DeviceOwner` gains `implementation: Literal["external", "lanbat-ca"]`,
  `dpcApk: str | None`, `packageId: str | None`, `caSha256: str | None`, and
  `versionCode: int | None`.

- [ ] **Step 1: Write failing preflight tests**

Cover:

```python
def run_preflight(device, manifest):
    adb = Adb("192.0.2.50", 5555)
    info = adb.connect()
    return preflight.reconcile(adb, info, manifest)

def by_target(outcomes):
    return {outcome.target: outcome for outcome in outcomes}

def test_missing_device_admin_feature_fails(device):
    device.state["features"] = []
    device.commit()
    outcome = by_target(run_preflight(device, managed_manifest()))["device-admin"]
    assert outcome.status == "failed"

def test_missing_dpm_fails_even_when_feature_is_advertised(device):
    device.state["commands"].remove("dpm")
    device.commit()
    assert by_target(run_preflight(device, managed_manifest()))["dpm"].status == "failed"

def test_headless_system_user_fails(device):
    device.state["headless"] = True
    device.commit()
    assert by_target(run_preflight(device, managed_manifest()))["user-mode"].status == "failed"

def test_accounts_mean_reset_required_not_unsupported(device):
    device.state["accounts"] = 1
    device.commit()
    outcome = by_target(run_preflight(device, managed_manifest()))["accounts"]
    assert outcome.status == "changed"
    assert "factory reset" in outcome.reason

def test_preflight_never_mutates_device(device):
    before = device.reload()
    run_preflight(device, managed_manifest())
    assert device.reload() == before
```

Define `managed_manifest()` in the test file by constructing `Manifest` with
an enabled `lanbat-ca` owner, component
`org.lanbat.dpc/.LanbatDeviceAdminReceiver`, all five required managed fields,
and no APKs by default. The same file adds direct assertions for the supported
device, conflicting owner name, selected APK minSdk, and selected APK ABI
cases.

Accounts and additional users produce `changed` with a “factory reset
required” reason, not `failed`, because they describe current state rather
than unsupported firmware.

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
nix build -L .#checks.x86_64-linux.android-provision
```

Expected: FAIL because the preflight module and manifest fields do not exist.

- [ ] **Step 3: Extend device-owner manifest parsing**

Use:

```python
@dataclass(frozen=True)
class DeviceOwner:
    enable: bool
    implementation: str
    component: str | None
    dpcApk: str | None = None
    packageId: str | None = None
    caSha256: str | None = None
    versionCode: int | None = None
```

Reject unknown implementations. Require `component` for `external`. Require
all five Lanbat fields for `lanbat-ca`. Keep old manifests working by
defaulting a missing implementation to `"external"`.

- [ ] **Step 4: Add read-only ADB queries**

Add methods or focused helpers for:

```text
pm has-feature android.software.device_admin
service check device_policy
command -v dpm
cmd user is-headless-system-user-mode
pm list users
dumpsys account
dumpsys device_policy
```

Treat an unavailable headless-mode command on pre-Android-14 devices as
conventional mode only when the SDK is below 34. On API 34+, an unavailable
or unparseable result is a failed capability check.

- [ ] **Step 5: Implement preflight outcomes**

Return one named outcome per capability and compatibility check. For every
selected APK, fail preflight when:

```python
apk.minSdk > info.sdk
```

or when the configured ABI is absent from `info.abis`. Do not call install,
push, settings, `dpm set-device-owner`, or any mutating command.

- [ ] **Step 6: Add the standalone CLI operation**

`preflight` connects exactly like plan/provision, prints device facts and
outcomes, and exits:

- `0` when outcomes contain only `ok` or `changed`;
- `1` when any check is `failed`;
- existing `2`/`3`/`4` codes for unreachable, unauthorized, or malformed
  manifests.

- [ ] **Step 7: Extend the fake ADB**

Add explicit fake state for `features`, `services`, `commands`, `headless`,
`users`, and account count. Unknown read-only commands must fail, ensuring
tests cannot pass because the fake silently accepted a probe.

- [ ] **Step 8: Run the complete Python suite**

Run:

```bash
nix build -L .#checks.x86_64-linux.android-provision
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add pkgs/android-provision
git commit -m "feat: preflight Android device owner support"
```

### Task 3: DPC Installation and Managed CA Reconciliation

**Files:**
- Create: `pkgs/android-provision/src/android_provision/resources/dpc.py`
- Create: `pkgs/android-provision/src/android_provision/resources/managed_ca.py`
- Create: `pkgs/android-provision/tests/test_dpc.py`
- Create: `pkgs/android-provision/tests/test_managed_ca.py`
- Modify: `pkgs/android-provision/src/android_provision/cli.py`
- Modify: `pkgs/android-provision/src/android_provision/adb.py`
- Modify: `pkgs/android-provision/src/android_provision/resources/device_owner.py`
- Modify: `pkgs/android-provision/tests/fake_adb.py`
- Modify: `pkgs/android-provision/tests/test_device_owner.py`
- Modify: `pkgs/android-provision/default.nix`

**Interfaces:**
- Consumes: the Lanbat `DeviceOwner` manifest fields from Task 2.
- Produces: resource order `(preflight, dpc, device_owner, managed_ca, apks, home, settings, cacerts, obtainium)`.
- `dpc.signer_digest(apk_path: str) -> str`; `dpc.installed_signer_digest(adb, package_id: str) -> str | None`.
- `managed_ca.read_status(adb, package_id: str) -> ManagedCaStatus`.

- [ ] **Step 1: Write failing DPC-resource tests**

Test:

```python
def run_dpc(device, manifest, *, apply=True):
    adb = Adb("192.0.2.50", 5555)
    info = adb.connect()
    return dpc.reconcile(adb, info, manifest, apply=apply, force=False)

def test_mismatched_installed_signer_fails_without_install(device, monkeypatch):
    device.state["packages"][DPC_PACKAGE] = 1
    device.commit()
    monkeypatch.setattr(dpc, "installed_signer_digest", lambda *_: "old")
    monkeypatch.setattr(dpc, "signer_digest", lambda *_: "new")
    outcomes = run_dpc(device, managed_manifest())
    assert outcomes[0].status == "failed"
    assert device.reload()["install_log"] == []

def test_external_owner_skips_lanbat_dpc_resource(device):
    assert run_dpc(device, external_manifest()) == []

def test_plan_reports_install_without_mutation(device):
    outcomes = run_dpc(device, managed_manifest(), apply=False)
    assert outcomes[0].status == "changed"
    assert DPC_PACKAGE not in device.reload()["packages"]
```

Define `DPC_PACKAGE`, `managed_manifest()`, and `external_manifest()` at the
top of the test file using the manifest interface from Task 2. The same file
adds direct tests for first installation, matching-signer upgrade, and
version-code idempotency.

- [ ] **Step 2: Write failing managed-CA tests**

Test matching installed status, owner false, fingerprint mismatch, malformed
JSON, timeout, and successful post-enrollment polling. Keep tests fast by
injecting `sleep=lambda _: None` and a small attempt count.

- [ ] **Step 3: Run focused tests to verify failure**

Run:

```bash
nix build -L .#checks.x86_64-linux.android-provision
```

Expected: FAIL because the resources do not exist.

- [ ] **Step 4: Add local and installed signer inspection**

Add `Adb.pull(remote, local)` and obtain the installed base APK from:

```text
pm path org.lanbat.dpc
```

Use Android build-tools `apksigner verify --print-certs` for both desired and
installed APKs, parsing the lowercase SHA-256 signer digest. Pull the installed
APK into `tempfile.TemporaryDirectory`. If the package exists and digests
differ, return `failed` before calling `adb install`.

- [ ] **Step 5: Implement DPC APK reconciliation**

For `implementation != "lanbat-ca"`, return no outcomes. Otherwise:

1. verify the desired APK is signed and readable;
2. compare installed and desired signer identities when installed;
3. install with `adb install -r` when absent, when its version code differs,
   or when managed-CA status shows that the compiled CA differs;
4. verify the package exists after installation.

Do not uninstall or downgrade an owner package.

- [ ] **Step 6: Move Device Owner ahead of CA work**

Preserve current external-owner behavior. For Lanbat mode, use the fixed
component from the manifest. A conflicting owner remains:

```python
Outcome(
    "deviceOwner",
    target,
    FAILED,
    f"owner already set to {existing}; a device owner cannot be replaced without a factory reset",
)
```

- [ ] **Step 7: Implement managed-CA status polling**

Invoke:

```text
am broadcast --receiver-foreground -a org.lanbat.dpc.STATUS -p org.lanbat.dpc
```

Parse the ordered-broadcast result data as JSON. Success requires all three:
owner true, exact lowercase `caSha256`, and installed true. Poll for at most
30 seconds after a new enrollment or DPC update. In plan mode report what
would be verified without broadcasting a mutation.

- [ ] **Step 8: Add apksigner to the provisioner closure**

Compose the same pinned Android build-tools package used by the DPC build and
add its `apksigner` to the wrapped CLI's `PATH`. Do not depend on a host-global
Android SDK.

- [ ] **Step 9: Assert resource ordering at CLI level**

Extend `test_cli.py` so a fake fresh box's command log proves:

```text
install DPC < set-device-owner < status broadcast < install ordinary APK
```

Also assert ordinary APK reconciliation still runs when owner enrollment
fails.

- [ ] **Step 10: Run the complete provisioner suite**

Run:

```bash
nix build -L .#checks.x86_64-linux.android-provision
```

Expected: PASS.

- [ ] **Step 11: Commit**

```bash
git add pkgs/android-provision
git commit -m "feat: reconcile Android DPC and managed CA"
```

### Task 4: NixOS Runtime Signing and Device Configuration

**Files:**
- Modify: `modules/server/android-devices.nix`
- Modify: `tests/android-devices.nix`
- Modify: `deployments/example/deploy.nix`
- Modify: `flake.nix`

**Interfaces:**
- Consumes: `pkgs/android-dpc`, `lanbat.hostSecrets`, and
  `config.lanbat.secrets`.
- Produces: `deviceOwner.implementation`; signing unit
  `android-dpc-prepare.service`; preflight unit
  `android-preflight-<device>.service`; signed APK
  `/var/lib/android-provision/dpc/lanbat-dpc.apk`.

- [ ] **Step 1: Add failing Nix evaluation cases**

Extend `tests/android-devices.nix` with:

```nix
managed = eval {
  bedroom = {
    host = "192.0.2.50";
    deviceOwner = {
      enable = true;
      implementation = "lanbat-ca";
    };
  };
};
```

Assert:

- managed mode does not require a user-supplied component;
- external mode still requires one;
- managed mode rejects a component override;
- managed mode creates prepare, preflight, plan, provision, and capture units;
- only prepare/plan/provision depend on the signed artifact;
- no managed device means no signing secrets or prepare unit;
- the manifest names the fixed package/component, version code, CA fingerprint,
  and runtime APK path.

Provide minimal test-harness options for `lanbat.hostSecrets` and
`lanbat.secrets` so standalone module evaluation remains supported.

- [ ] **Step 2: Run the Nix check to verify failure**

Run:

```bash
nix build -L .#checks.x86_64-linux.android-devices
```

Expected: FAIL because managed mode and units do not exist.

- [ ] **Step 3: Add the implementation option**

Extend `deviceOwner`:

```nix
implementation = mkOption {
  type = types.enum [ "external" "lanbat-ca" ];
  default = "external";
};
```

For `external`, retain the current component requirement. For `lanbat-ca`,
derive the fixed component, DPC package, public CA fingerprint, and runtime
signed path; reject a manually supplied component.

- [ ] **Step 4: Declare conditional host secrets**

When at least one enabled device uses Lanbat mode:

```nix
lanbat.hostSecrets.android-dpc-keystore = {
  owner = "root";
  mode = "0400";
};
lanbat.hostSecrets.android-dpc-keystore-password = {
  owner = "root";
  mode = "0400";
};
```

Read both only through `config.lanbat.secrets`.

- [ ] **Step 5: Implement atomic runtime signing**

Create `android-dpc-prepare.service` with
`StateDirectory=android-provision`, `UMask=0077`, and a script that:

```bash
tmp=$(mktemp /var/lib/android-provision/dpc/.lanbat-dpc.XXXXXX.apk)
trap 'rm -f "$tmp"' EXIT
apksigner sign \
  --ks "$KEYSTORE" \
  --ks-key-alias lanbat-dpc \
  --ks-pass "file:$PASSWORD_FILE" \
  --key-pass "file:$PASSWORD_FILE" \
  --out "$tmp" \
  "$UNSIGNED_APK"
apksigner verify --verbose --print-certs "$tmp"
install -m 0600 "$tmp" /var/lib/android-provision/dpc/lanbat-dpc.apk.new
mv -f /var/lib/android-provision/dpc/lanbat-dpc.apk.new \
  /var/lib/android-provision/dpc/lanbat-dpc.apk
```

Create the DPC directory mode 0700. The service must finish before managed
plan or provision units. Preflight has no runtime dependency on the signed
artifact, although enabling managed mode still requires the encrypted signing
secrets to satisfy Nix evaluation.

- [ ] **Step 6: Generate the managed manifest fields**

For Lanbat mode emit:

```json
{
  "enable": true,
  "implementation": "lanbat-ca",
  "component": "org.lanbat.dpc/.LanbatDeviceAdminReceiver",
  "packageId": "org.lanbat.dpc",
  "dpcApk": "/var/lib/android-provision/dpc/lanbat-dpc.apk",
  "caSha256": "the lowercase DER fingerprint from the DPC package",
  "versionCode": 1
}
```

External mode emits null managed fields.

- [ ] **Step 7: Add the preflight systemd unit**

`android-preflight-<name>` uses the same ADB HOME and manifest as the other
units but executes `android-provision preflight`. It has no dependency on the
signing service and no automatic timer or target.

- [ ] **Step 8: Add the package check to the flake**

Expose the DPC build as `checks.x86_64-linux.android-dpc`, using the example
CA. Keep the existing `pkgs-build` smoke assertion as a second integration
check.

- [ ] **Step 9: Run module and example evaluation**

Run:

```bash
nix build -L .#checks.x86_64-linux.android-devices
nix eval --raw .#nixosConfigurations.example-server.config.system.build.toplevel.drvPath
```

Expected: both succeed.

- [ ] **Step 10: Commit**

```bash
git add modules/server/android-devices.nix tests/android-devices.nix deployments/example/deploy.nix flake.nix
git commit -m "feat: sign and provision managed Android devices"
```

### Task 5: Android Application Pins and Reference Configuration

**Files:**
- Modify: `pkgs/android-provision/apks.lock.json` through `android-update`
- Modify: `deployments/example/deploy.nix`
- Modify: `tests/android-devices.nix`

**Interfaces:**
- Produces lock keys `home-assistant/android` and
  `theothernt/AerialViews`; keeps existing Snapdroid, Key Mapper, and Argosy
  entries.

- [ ] **Step 1: Write failing lock-resolution assertions**

Add an example device using:

```nix
packages = [
  "de.badaix.snapcast"
  "io.github.sds100.keymapper"
];
github = [
  {
    repo = "home-assistant/android";
    asset = "automotive-minimal-release.apk";
  }
  {
    repo = "theothernt/AerialViews";
    asset = "aerial-views-*.apk";
  }
];
```

Set its ABI to `armeabi-v7a`, matching the reference box. Assert the module
evaluates and each lock entry has either that ABI or `universal`.

- [ ] **Step 2: Run the check to verify failure**

Run:

```bash
nix build -L .#checks.x86_64-linux.android-devices
```

Expected: FAIL naming missing lock entries.

- [ ] **Step 3: Regenerate the complete lockfile**

Run one complete update, retaining every existing entry:

```bash
nix run .#android-update -- "" \
  --fdroid de.badaix.snapcast \
  --fdroid io.github.sds100.keymapper \
  --github 'rommapp/argosy-launcher=argosy-v*.[0-9].apk' \
  --github 'home-assistant/android=automotive-minimal-release.apk' \
  --github 'theothernt/AerialViews=aerial-views-*.apk'
```

Review that Home Assistant's resolved stable release postdates the merged
user-CA trust fix and that its metadata reports minSdk 29 or lower. Verify
the command retained all three prior entries and added exactly two.

- [ ] **Step 4: Update the example device**

Enable `deviceOwner.implementation = "lanbat-ca"` and use the four approved
apps. Do not set Aerial Views as screensaver automatically and do not add
deployment-specific launcher or account state.

- [ ] **Step 5: Run focused checks**

Run:

```bash
nix build -L .#checks.x86_64-linux.android-devices
nix build -L .#checks.x86_64-linux.android-provision
nix eval --raw .#nixosConfigurations.example-server.config.system.build.toplevel.drvPath
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add pkgs/android-provision/apks.lock.json deployments/example/deploy.nix tests/android-devices.nix
git commit -m "feat: pin Home Assistant Android TV apps"
```

### Task 6: Signing Identity Helper and Operator Documentation

**Files:**
- Create: `pkgs/android-dpc-keys/default.nix`
- Create: `pkgs/android-dpc-keys/android-dpc-keys.sh`
- Create: `pkgs/android-dpc-keys/test.sh`
- Modify: `flake.nix`
- Modify: `secrets/secrets.nix.example`
- Modify: `secrets/README.md`
- Modify: `docs/android-devices.md`
- Modify: `docs/deployment-checklist.md`
- Modify: `docs/security.md`
- Modify: `docs/failure-modes.md`
- Modify: `deployments/homelab/deploy.nix.example`
- Modify: `tests/pkgs-build.nix`

**Interfaces:**
- Produces: `nix run .#android-dpc-keys`, which creates
  `secrets/android-dpc-keystore.age` and
  `secrets/android-dpc-keystore-password.age` without persisting plaintext.

- [ ] **Step 1: Write the helper's shell test**

Use fake `keytool` and `agenix` executables. Assert the helper:

- refuses when either destination already exists;
- requires `secrets/secrets.nix`;
- generates alias `lanbat-dpc`;
- requests PKCS12;
- sends binary keystore and one-line password to separate agenix calls;
- removes its temporary directory on success and failure; and
- prints the signing-identity backup warning.

- [ ] **Step 2: Run the package smoke check to verify failure**

Run:

```bash
nix build -L .#checks.x86_64-linux.pkgs-build
```

Expected: FAIL because the helper does not exist.

- [ ] **Step 3: Implement the helper**

Use `mktemp -d`, `trap`, `openssl rand`, and `keytool -genkeypair` with:

```text
alias: lanbat-dpc
store type: PKCS12
algorithm: EC
validity: 10,950 days
distinguished name: CN=Lanbat Android DPC
```

Encrypt the temporary keystore and password through agenix stdin. Never echo
the password or leave a plaintext file after the trap runs.

- [ ] **Step 4: Expose and smoke-test the helper**

Add `apps.x86_64-linux.android-dpc-keys` and include its test in
`tests/pkgs-build.nix`.

- [ ] **Step 5: Add secret recipient entries**

In `secrets/secrets.nix.example`, add both files to `serverKeys`. Explain that
losing or rotating the identity prevents in-place DPC updates and requires a
device reset.

- [ ] **Step 6: Document capability and reset workflow**

Update `docs/android-devices.md` with:

1. compatibility is not universal;
2. `systemctl start android-preflight-<box>`;
3. interpretation of supported, reset-required, and unsupported outcomes;
4. signing identity creation and backup;
5. baseline capture before reset;
6. the exact reset/enrollment order;
7. managed CA scope and app opt-in limitation;
8. DPC removal requiring another reset; and
9. Home Assistant sign-in and idempotency verification.

- [ ] **Step 7: Update security and failure documentation**

State that the DPC trusts the existing internal CA only for apps opting into
user CAs, that the DPC signing key is a high-value deployment secret, and that
preflight cannot prove vendor enrollment behavior. Add recovery actions for
lost signing identity, unsupported firmware, conflicting owner, and failed
post-reset enrollment.

- [ ] **Step 8: Update the deployment template**

Show managed mode and the four-app set in
`deployments/homelab/deploy.nix.example`, but keep it commented and include
the reset warning.

- [ ] **Step 9: Run docs/package checks**

Run:

```bash
nix build -L .#checks.x86_64-linux.pkgs-build
nix fmt
git diff --check
```

Expected: all pass and formatting changes are limited to touched files.

- [ ] **Step 10: Commit**

```bash
git add pkgs/android-dpc-keys flake.nix secrets/secrets.nix.example secrets/README.md \
  docs/android-devices.md docs/deployment-checklist.md docs/security.md \
  docs/failure-modes.md deployments/homelab/deploy.nix.example tests/pkgs-build.nix
git commit -m "feat: add Android device owner setup"
```

### Task 7: Integrated Verification

**Files:**
- Modify only files needed to correct failures found by these checks.

**Interfaces:**
- Consumes all earlier tasks.
- Produces a buildable, reviewable implementation ready for physical
  preflight, but does not claim successful device deployment.

- [ ] **Step 1: Run formatting and static diff checks**

Run:

```bash
nix fmt
git diff --check
```

Expected: PASS.

- [ ] **Step 2: Run focused builds independently**

Run:

```bash
nix build -L .#checks.x86_64-linux.android-dpc
nix build -L .#checks.x86_64-linux.android-provision
nix build -L .#checks.x86_64-linux.android-devices
nix build -L .#checks.x86_64-linux.pkgs-build
```

Expected: PASS.

- [ ] **Step 3: Evaluate the example host**

Run:

```bash
nix eval --raw .#nixosConfigurations.example-server.config.system.build.toplevel.drvPath
```

Expected: a derivation path and exit 0.

- [ ] **Step 4: Run repository checks in proportion to available memory**

On a machine with at least 16 GB free:

```bash
nix flake check --no-build --all-systems
```

Otherwise run the focused checks above plus:

```bash
nix build .#checks.x86_64-linux.{assertions,plugins,settings-guard,validate-deploy,load-deployments}
```

Expected: PASS. Record any check not run due to memory or architecture.

- [ ] **Step 5: Review the complete branch**

Check:

```bash
git status --short
git log --oneline --decorate -10
git diff master...HEAD --stat
```

Confirm no real address, signing key, password, snapshot, generated signed
APK, or unrelated pre-existing work was committed.

- [ ] **Step 6: Commit verification-only fixes**

If checks required code changes:

```bash
git add -p
git diff --cached --check
git commit -m "fix: complete Android device owner verification"
```

Stage only verification-fix hunks shown by `git add -p`; reject every
pre-existing unrelated hunk. If no changes were required, do not create an
empty commit.

### Task 8: Physical Reference-device Rollout

**Files:**
- Modify privately: `deployments/homelab/deploy.nix`
- Create privately through agenix:
  `secrets/android-dpc-keystore.age`
- Create privately through agenix:
  `secrets/android-dpc-keystore-password.age`
- Create privately on the server:
  `/var/lib/android-provision/bedroom/snapshots/*.json`

**Interfaces:**
- Consumes the verified implementation and the physical Homatics box.
- Produces a managed reference box only after explicit human confirmation of
  the reset. None of the private artifacts are committed.

- [ ] **Step 1: Generate and back up the signing identity**

Run:

```bash
nix run .#android-dpc-keys
nix run .#secrets-recipients
```

Add both encrypted files to private secret management and verify the server is
a recipient. Back up the encrypted files and `secrets/secrets.nix` before
continuing.

- [ ] **Step 2: Enable managed mode without running provisioning**

After the signing secrets exist, set the real bedroom device to Lanbat managed
mode and deploy the server configuration. None of the Android units has a
timer or `wantedBy`, so this creates the preflight and preparation units
without contacting, enrolling, or resetting the box.

- [ ] **Step 3: Run the non-mutating capability preflight**

Run on the server:

```bash
systemctl start android-preflight-bedroom
journalctl -u android-preflight-bedroom --no-pager
```

Expected: device-admin, policy service, `dpm`, conventional user mode, SDK,
and ABI checks pass. Accounts may report “factory reset required.” Stop the
rollout permanently for this device if a mandatory capability fails.

- [ ] **Step 4: Capture and preserve the baseline**

Run:

```bash
systemctl start android-capture-bedroom
journalctl -u android-capture-bedroom --no-pager
```

Copy the newest snapshot to a second private location. Record the exact
launcher component, LTV Launcher source, Argosy source, Wholphin source,
settings, and every manual/Play-only app.

- [ ] **Step 5: Complete the private restore manifest**

Update `deployments/homelab/deploy.nix` with every provisionable baseline app,
the four approved apps, the captured home activity, and:

```nix
deviceOwner = {
  enable = true;
  implementation = "lanbat-ca";
};
```

Regenerate the complete APK lockfile first if the baseline introduces another
supported F-Droid or GitHub source. Do not put snapshots, addresses, or
account data in tracked files.

- [ ] **Step 6: Deploy and verify server-side preparation**

Deploy, then run:

```bash
systemctl start android-dpc-prepare
systemctl status android-dpc-prepare --no-pager
ls -l /var/lib/android-provision/dpc/lanbat-dpc.apk
```

Expected: service success and APK mode 0600 in a mode-0700 directory.

- [ ] **Step 7: Present the reset checkpoint**

Before resetting, show the operator:

- preflight output;
- saved baseline path and backup;
- manual apps/sign-ins that cannot be restored;
- warning that Device Owner removal requires another reset.

Wait for explicit confirmation at this checkpoint. Do not automate the reset.

- [ ] **Step 8: Reset and enroll before accounts**

Factory-reset manually, complete only enough setup to enable network ADB,
avoid adding a Google account, authorize the existing server key, then run:

```bash
systemctl start android-provision-bedroom
journalctl -u android-provision-bedroom --no-pager
```

Expected: DPC installed, owner set to
`org.lanbat.dpc/.LanbatDeviceAdminReceiver`, exact CA fingerprint verified,
and ordinary apps reconciled.

- [ ] **Step 9: Verify Home Assistant HTTPS**

Open the deployment's configured `https://ha.` service URL in Home Assistant
Automotive Minimal. Confirm:

- no certificate bypass or warning;
- successful authentication;
- dashboard loads;
- a state change updates live over the websocket.

- [ ] **Step 10: Restore manual state and prove idempotency**

Restore unavoidable Play-only apps and sign-ins. Run provisioning a second
time:

```bash
systemctl start android-provision-bedroom
journalctl -u android-provision-bedroom --no-pager
```

Expected: all managed resources report `ok`.

- [ ] **Step 11: Capture and compare the final state**

Run:

```bash
systemctl start android-capture-bedroom
snapshots=(/var/lib/android-provision/bedroom/snapshots/*.json)
android-provision diff "${snapshots[-2]}" "${snapshots[-1]}"
```

Account for every remaining difference. Update private configuration for any
portable omission and document genuinely manual restoration steps.

- [ ] **Step 12: Record deployment evidence**

Record the NixOS generation, DPC CA fingerprint, app versions, preflight
result, first-run result, idempotent second-run result, and baseline-diff
summary in the deployment notes. Do not commit device identifiers or snapshot
contents.
