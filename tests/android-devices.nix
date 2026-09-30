# tests/android-devices.nix
#
# Evaluation checks for the androidDevices module: the units it produces and
# the mistakes it must reject.
{ lib, pkgs }:

let
  eval =
    devices:
    (lib.evalModules {
      modules = [
        {
          options.assertions = lib.mkOption { default = [ ]; };
          options.environment.systemPackages = lib.mkOption { default = [ ]; };
          options.systemd.services = lib.mkOption { default = { }; };
          config._module.args = { inherit pkgs; };
        }
        ../modules/server/android-devices.nix
        { androidDevices = devices; }
      ];
    }).config;

  failures = cfg: lib.filter (a: !a.assertion) cfg.assertions;

  ok = eval {
    bedroom = {
      host = "192.0.2.50";
      packages = [ "de.badaix.snapcast" ];
    };
  };

  duplicate = eval {
    bedroom = {
      host = "192.0.2.50";
      packages = [ "de.badaix.snapcast" ];
    };
    lounge = {
      host = "192.0.2.50";
      packages = [ "de.badaix.snapcast" ];
    };
  };

  ownerWithoutComponent = eval {
    bedroom = {
      host = "192.0.2.50";
      deviceOwner.enable = true;
    };
  };

  unlocked = eval {
    bedroom = {
      host = "192.0.2.50";
      packages = [ "com.example.not.in.lockfile" ];
    };
  };

  noMatchingVariant = eval {
    bedroom = {
      host = "192.0.2.50";
      # de.badaix.snapcast ships arm64-v8a/armeabi-v7a/x86/x86_64 variants and
      # no universal, so an unrelated abi resolves to nothing.
      abi = "mips64";
      packages = [ "de.badaix.snapcast" ];
    };
  };

  badNamespace = eval {
    bedroom = {
      host = "192.0.2.50";
      # typo: should be "global"
      settings.globl.screen_off_timeout = 600000;
    };
  };

  withHome = eval {
    bedroom = {
      host = "192.0.2.50";
      homeActivity = "com.nendo.argosy/.MainActivity";
    };
  };

  badHomeActivity = eval {
    bedroom = {
      host = "192.0.2.50";
      # missing the "/activity" part
      homeActivity = "com.nendo.argosy";
    };
  };

  withArgosy = eval {
    bedroom = {
      host = "192.0.2.50";
      github = [
        {
          repo = "rommapp/argosy-launcher";
          asset = "argosy-v*.[0-9].apk";
        }
      ];
      homeActivity = "com.nendo.argosy/.MainActivity";
      # The reference box runs 32-bit Android; the universal APK covers it.
      abi = "armeabi-v7a";
    };
  };

  expect = name: cond: if cond then "" else "FAIL: ${name}\n";
in
pkgs.runCommand "android-devices-check" { } ''
  errors="${
    expect "a valid device produces both units" (
      (ok.systemd.services ? "android-provision-bedroom")
      && (ok.systemd.services ? "android-provision-bedroom-plan")
    )
    + expect "a valid device raises no assertion" (failures ok == [ ])
    + expect "duplicate host:port is rejected" (lib.length (failures duplicate) == 1)
    + expect "deviceOwner without component is rejected" (
      lib.length (failures ownerWithoutComponent) == 1
    )
    + expect "a package missing from the lockfile is rejected" (lib.length (failures unlocked) == 1)
    + expect "an abi with no matching variant and no universal is rejected" (
      lib.length (failures noMatchingVariant) == 1
    )
    + expect "an unknown settings namespace is rejected" (lib.length (failures badNamespace) == 1)
    + expect "the unknown settings namespace message names the device and the namespace" (
      let
        msgs = map (a: a.message) (failures badNamespace);
      in
      lib.any (m: lib.hasInfix "bedroom" m && lib.hasInfix "globl" m) msgs
    )
    + expect "duplicate host:port message names both devices" (
      let
        msgs = map (a: a.message) (failures duplicate);
      in
      lib.any (m: lib.hasInfix "bedroom" m && lib.hasInfix "lounge" m) msgs
    )
    + expect "a valid device produces a capture unit" (ok.systemd.services ? "android-capture-bedroom")
    + expect "the capture unit writes into the device's snapshot directory" (
      lib.hasInfix "/var/lib/android-provision/bedroom/snapshots"
        ok.systemd.services."android-capture-bedroom".script
    )
    + expect "a device with homeActivity evaluates cleanly" (
      failures withHome == [ ] && withHome.systemd.services ? "android-provision-bedroom"
    )
    + expect "a homeActivity without package/activity form is rejected" (
      lib.length (failures badHomeActivity) == 1
    )
    + expect "argosy resolves from the lockfile" (failures withArgosy == [ ])
  }"
  if [ -n "$errors" ]; then
    printf '%s' "$errors" >&2
    exit 1
  fi
  touch $out
''
