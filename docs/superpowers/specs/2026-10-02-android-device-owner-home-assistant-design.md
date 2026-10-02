# Android Device Owner and Home Assistant Design

## Context

The Android provisioning plugin can install pinned APKs, restore settings, and
deliver the homelab CA certificate to an Android TV box. On Android 11 and
later, however, ADB cannot open the CA installer. The reference Homatics Box R
4K Plus runs Android 14 and its TV settings application has no certificate
screen, so the delivered certificate cannot enter the user trust store.

This prevents the official Home Assistant companion app from connecting to
`https://ha.<domain>`. A per-device firewall exception to Home Assistant's
plain HTTP port would expose its bearer token to the LAN and is not an
acceptable solution. Public ACME certificates through the domain's DNS
provider were considered, but this deployment will not hold provider API
credentials.

Android's Device Owner API can install a CA without the missing settings UI.
The official Home Assistant app opts into Android's user CA store, including
its non-WebView HTTP client in releases containing
home-assistant/android#7044. A managed CA therefore solves Home Assistant's
connection problem without weakening TLS validation.

## Goals

- Install and verify the profile's existing Caddy root CA on a compatible,
  unrooted Android TV box.
- Keep the CA private key off the Android device; the DPC receives only the
  public root certificate.
- Use a deployment-specific APK signing key that never enters Git or the Nix
  store.
- Provision the official Home Assistant Android TV app and a small,
  TV-appropriate app set through the existing pinned-APK mechanism.
- Detect unsupported devices before the operator factory-resets them, as far
  as Android permits without attempting enrollment.
- Restore the reference box after its required reset from a private baseline
  snapshot and report everything that cannot be restored automatically.
- Preserve the provisioner's plan/apply/idempotency model and per-resource
  outcomes.

## Non-goals

- Supporting every Android TV implementation. Device administration is not a
  required Android TV compatibility feature.
- Installing a CA for applications that ignore Android's user CA store. In
  particular, this design does not claim to fix Wholphin, Kodi, Jellyfin, or
  YouTube.
- Factory-resetting a device automatically.
- Silently replacing or removing an existing Device Owner.
- General mobile-device management, remote policy control, telemetry, or a
  management server.
- Replacing the internal CA with public ACME certificates.
- Making Device Owner the default for Android devices. It remains explicit
  per device.

## Compatibility and Preflight

Android exposes Device Owner APIs from Android 5, but Android Television
devices are not required to implement the full device-administration feature.
Vendor images can omit the feature, remove managed provisioning, restrict the
`dpm` shell command, or use Android 14's headless-system-user mode.

Each device that enables the Lanbat DPC gets an
`android-preflight-<device>` unit and an equivalent CLI operation. It performs
read-only checks for:

- `android.software.device_admin`;
- the device-policy service and `dpm` command;
- Android SDK and ABI compatibility with the DPC and selected APKs;
- conventional system-user mode, rejecting headless-system-user mode;
- an existing Device Owner, reporting its component when present;
- configured accounts and users that would prevent shell enrollment;
- enough information to explain that a provisioned device still needs a
  reset even if all capability checks pass.

The normal plan and provision operations repeat the capability checks. A
failed Device Owner preflight blocks DPC enrollment and managed-CA work but
does not prevent independent APK and snapshot operations.

Preflight cannot prove that a vendor will accept `dpm set-device-owner`.
Android exposes no non-mutating enrollment trial, and
`isProvisioningAllowed` normally returns false once initial setup is complete.
The definitive compatibility test therefore happens immediately after the
manual reset, before accounts, app sign-ins, or restoration work. Failure at
that point is reported clearly and the box remains usable after completing
ordinary setup.

The first implementation supports conventional single-user Android TV
devices only. Headless-system-user affiliated mode is rejected rather than
partially managed.

## Architecture

The feature adds four cooperating pieces:

1. A minimal Android Device Policy Controller in `pkgs/` that contains the
   profile's public CA and no network client.
2. Runtime APK signing on the NixOS server using agenix-provisioned signing
   material.
3. A Device Owner resource and managed-CA status resource in
   `android-provision`, ordered ahead of resources that depend on trusted
   HTTPS.
4. Per-device configuration selecting the Lanbat DPC and pinned Android apps.

Generic external Device Owner components remain supported. Managed CA
installation is available only when the device selects the Lanbat DPC
implementation; the configuration rejects contradictory combinations during
Nix evaluation.

## Device Policy Controller

The DPC package has a stable package name and admin receiver component owned
by this project. It contains:

- one `DeviceAdminReceiver`;
- the profile's public root certificate as a raw resource;
- code that calls `DevicePolicyManager.installCaCert`;
- code that verifies the certificate with `hasCaCertInstalled`;
- a package-scoped, read-only status receiver used by the provisioner; and
- no launcher, Internet permission, remote command channel, analytics, or
  general policy UI.

The DPC reconciles the CA when it becomes Device Owner, after boot, and after
its package is replaced. It records the exact bytes of the previously managed
Lanbat CA in private app storage. During rotation it installs and verifies the
new CA first, removes only the recorded previous CA, then records the new
certificate. It never enumerates and removes unrelated user CAs.

The status receiver reports whether the app is Device Owner, the SHA-256
fingerprint compiled into the APK, and whether that exact CA is installed.
It exposes no mutating operation. The provisioner treats a missing,
mismatched, or unverifiable fingerprint as a failure rather than relying on
an ADB-side marker.

The DPC is intentionally not removable through provisioning. Android does
not permit an ordinary replacement Device Owner, and removing management
requires another deliberate factory reset.

## APK Signing and Secrets

Nix builds an unsigned, profile-specific DPC APK containing the public CA.
The unsigned artifact is safe in the Nix store. A server-side preparation
unit signs it into a mode-0700 directory under
`/var/lib/android-provision/dpc/` before any managed device unit runs.

The signing identity consists of:

- an agenix-protected PKCS#12 Android signing keystore; and
- an agenix-protected password file.

Both requirements exist only when at least one enabled device selects the
Lanbat DPC. The example profile's `secrets.provider = "none"` satisfies
evaluation with placeholders, but no signing unit is expected to run there.
A helper command generates a new per-deployment identity and prints the
commands needed to encrypt the two files. No private key, password, signed
APK, or device snapshot is committed.

The preparation unit signs to a temporary file, verifies the resulting APK
with `apksigner`, and atomically renames it into place. Provisioning fails
before contacting a device if signing or verification fails. The same
identity must be retained for future DPC upgrades because Android accepts an
update only when its signature matches the installed package.

## Provisioning Flow

For a device using the Lanbat DPC, reconciliation runs in this order:

1. Validate the manifest and server-side signed DPC artifact.
2. Connect over the existing persistent ADB identity and gather device facts.
3. Run the Device Owner compatibility checks.
4. Install or update the signed DPC APK.
5. Read the current owner. If none exists, set the DPC as owner; if another
   owner exists, fail without changing it.
6. Poll the DPC's read-only status until the desired CA is verified or a
   bounded timeout expires.
7. Reconcile ordinary pinned APKs.
8. Reconcile home activity and Android settings.
9. Deliver CA files to `Download` as before for apps such as Argosy that
   implement their own import.
10. Reconcile Obtainium URLs.

Planning reports each prospective action but never installs the DPC or sets
an owner. A plan on a pre-reset device explicitly says that capability checks
cannot guarantee enrollment.

Failures retain the existing independent-resource behavior. A DPC install,
owner, or managed-CA failure blocks only dependent managed-CA verification;
ordinary apps continue so the final report provides a complete picture.
Connection and authorization failures still stop before reconciliation.

## Android App Set

Apps remain explicit per device rather than becoming global defaults. The
reference bedroom device will declare:

- Home Assistant's official Automotive Minimal APK from
  `home-assistant/android`, requiring Android 10 or later;
- Aerial Views from `theothernt/AerialViews`;
- Key Mapper from F-Droid;
- Snapdroid from F-Droid; and
- every currently installed, provisionable app needed to restore the
  pre-reset baseline.

The Home Assistant asset must be a stable release containing the user-CA
trust-manager fix. Its GitHub release asset and all other APKs are resolved
and pinned by `android-update`; provisioning never downloads an unpinned APK.

Aerial Views is installed as a screensaver but is not automatically connected
to Immich because its user-CA behavior has not been established. Selecting it
as the active screensaver can remain a documented on-screen step unless a
captured setting proves portable on the reference box.

The baseline determines the exact launcher component, Argosy source,
Wholphin source, and any Play-only applications. Items without a supported
source are listed as manual restoration work instead of being silently
omitted. The existing launcher is restored only after its APK is present and
its captured component has been verified.

## Reset and Recovery Workflow

The operator follows this sequence:

1. Run the preflight unit on the current box. Stop if a mandatory capability
   is absent.
2. Capture a fresh private baseline snapshot and copy it to a second private
   location.
3. Review the generated app-source and settings report. Add every supported
   current app and the exact home activity to the deployment configuration.
4. Deploy the configuration and verify that the signed DPC artifact and
   provision/plan units are ready, without running them against the current
   box.
5. Factory-reset the box manually.
6. Complete only enough setup to enable network ADB; do not add an account.
7. Authorize the server's existing ADB key.
8. Run provisioning. Device Owner enrollment is attempted before app
   restoration or sign-in.
9. Confirm the DPC status reports the expected CA fingerprint.
10. Open Home Assistant at `https://ha.<domain>` and authenticate normally.
11. Restore manual apps and sign-ins, including applications unavailable from
    the supported sources.
12. Capture a post-restoration snapshot and diff it against the baseline.

If enrollment fails after reset, the tool stops managed-CA work and prints the
vendor response. The operator can either complete normal unmanaged setup or
reset again after correcting a known configuration problem. The tool never
loops resets or hides the failure.

## Error Handling

- Missing device-admin feature, headless-user mode, incompatible SDK, or a
  vendor-disabled policy service: failed preflight with no device mutation.
- Existing Device Owner with the desired component: idempotent success.
- Existing Device Owner with another component: hard failure naming it; no
  replacement attempt.
- Accounts or users preventing enrollment: hard failure explaining that a
  clean reset is required.
- DPC signature mismatch: fail before `adb install`; never uninstall the
  installed owner package.
- DPC update rejected by Android: preserve the installed DPC and report
  stderr.
- CA install returns false, status fingerprint differs, or status times out:
  failed managed-CA outcome; do not claim trust was installed.
- Home Assistant APK below its minimum SDK: skipped using the existing APK
  compatibility outcome, and called out by preflight before reset.
- Unsupported or Play-only baseline app: explicit manual-restoration entry.

## Security Properties

- Home Assistant continues to use HTTPS and normal hostname and certificate
  validation.
- Only the public CA reaches the device.
- The APK signing private key and password remain encrypted at rest and are
  read only by the server-side signing unit.
- The DPC has no network permission or writable exported control surface.
- CA rotation removes only the prior certificate installed by this DPC.
- APKs are source-resolved, hash-pinned, and installed from the Nix store or
  the locally verified signed DPC artifact.
- Device Owner is explicit, visible in configuration, and requires the
  operator's manual reset.

Trusting the internal CA means any leaf certificate signed by that CA is
trusted by Home Assistant and other apps that opt into user CAs. Protecting
the Caddy root private key remains critical. Device Owner also grants broad
platform authority even though this DPC uses little of it; compromise of the
DPC signing identity could permit a malicious update, which is why that
identity is deployment-specific and secret.

## Testing and Verification

Automated tests cover:

- manifest parsing and Nix option assertions for Lanbat versus external DPCs;
- preflight parsing for supported, unsupported, headless, already-owned, and
  account-bearing fake devices;
- resource ordering: DPC install, owner assignment, CA verification, then
  ordinary resources;
- plan mode making no changes;
- idempotent owner and CA status;
- conflicting owner, rejected enrollment, signature mismatch, CA mismatch,
  and timeout outcomes;
- DPC CA rotation preserving unrelated user CAs;
- DPC APK compilation and signature verification;
- APK lock entries and ABI/minimum-SDK behavior;
- the focused Android provisioning and settings checks; and
- example-server evaluation.

The physical acceptance test on the reference Homatics box is mandatory
before documentation claims the path works:

1. successful preflight before reset;
2. successful enrollment after reset;
3. status reports the configured CA fingerprint as installed;
4. Home Assistant loads over `https://ha.<domain>` without bypassing TLS;
5. API login and live updates work;
6. a second provision run is entirely idempotent; and
7. the final snapshot diff accounts for every baseline difference.

## Documentation Changes

- Extend `docs/android-devices.md` with compatibility limits, preflight,
  signing identity setup, reset runbook, CA behavior, and removal semantics.
- Add the two conditional signing secrets to the example secret inventory.
- Update the deployment checklist with Device Owner preparation and the
  irreversible-reset warning.
- Update security documentation with the managed user-CA trust model and DPC
  signing-key threat.
- Update failure modes with unsupported firmware, lost signing identity, and
  failed post-reset enrollment.

## Rollout

The first rollout targets only the existing bedroom Homatics box. No other
device enables Device Owner until it independently passes preflight and the
operator accepts a reset.

Implementation is complete when automated checks pass and the units,
configuration, secrets, and documentation are ready. Deployment success is a
separate milestone requiring the physical acceptance test; it must not be
inferred from Nix evaluation or an emulator.
