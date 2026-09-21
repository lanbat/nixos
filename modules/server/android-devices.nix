# modules/server/android-devices.nix
#
# Declarative provisioning for Android TV boxes over ADB.  Enabled through the
# lanbat-android plugin; configures nothing when no devices are declared.
#
# What it does
# ------------
# Each device in androidDevices becomes a manifest (apps pinned by
# pkgs/android-provision/apks.lock.json, CA certificates, settings, an
# Obtainium URL list) plus a oneshot unit that converges the box to it.
# Nothing runs on a timer: a box is provisioned when asked, never while
# someone is watching it.
#
# ADB identity
# ------------
# adb reads its client key from $HOME/.android/adbkey, so the units run with
# HOME pointing at the state directory and adb creates the key there once.
# The first connection to a box raises an on-screen "Allow USB debugging?"
# dialog, accepted once with "always allow" -- a key regenerated per
# activation would re-prompt on every run, in front of the TV.
#
# What it deliberately does not do
# --------------------------------
# It never uninstalls anything, and it never factory-resets a box.  Removing
# an app from the configuration removes nothing from the device.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  inherit (lib) mkOption types;

  devices = lib.filterAttrs (_: d: d.enable) config.androidDevices;

  provisioner = pkgs.callPackage ../../pkgs/android-provision { };

  lock = lib.importJSON ../../pkgs/android-provision/apks.lock.json;

  # One fetchurl per locked APK variant actually needed by a device.
  fetchApk =
    entry: abi:
    let
      variant = entry.variants.${abi} or entry.variants.universal;
    in
    pkgs.fetchurl {
      url = variant.url;
      hash = variant.sha256;
      name = "${entry.packageId}-${toString entry.versionCode}.apk";
    };

  apkEntries =
    device:
    let
      keys = device.packages ++ (map (g: g.repo) device.github);
    in
    map (
      key:
      let
        entry = lock.${key};
      in
      {
        inherit (entry)
          packageId
          versionCode
          versionName
          minSdk
          source
          ;
        path = "${fetchApk entry device.abi}";
      }
    ) keys;

  obtainiumFile =
    device:
    pkgs.writeText "obtainium-urls.txt" (lib.concatMapStrings (o: o.url + "\n") device.obtainium);

  manifestFor =
    name: device:
    pkgs.writeText "android-manifest-${name}.json" (
      builtins.toJSON {
        device = name;
        inherit (device)
          host
          port
          abi
          allowDowngrade
          ;
        apks = apkEntries device;
        caCerts = map (cert: {
          name = baseNameOf (toString cert);
          sha256 = builtins.hashFile "sha256" cert;
          path = "${cert}";
        }) device.caCerts;
        settings = device.settings;
        obtainium =
          if device.obtainium == [ ] then
            null
          else
            {
              path = "${obtainiumFile device}";
              sha256 = builtins.hashString "sha256" (lib.concatMapStrings (o: o.url + "\n") device.obtainium);
            };
        deviceOwner = {
          inherit (device.deviceOwner) enable component;
        };
      }
    );

  unitFor =
    name: device: plan:
    let
      suffix = if plan then "-plan" else "";
      verb = if plan then "plan" else "provision";
    in
    lib.nameValuePair "android-provision-${name}${suffix}" {
      description = "${if plan then "Plan" else "Apply"} provisioning for Android device ${name}";
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        StateDirectory = "android-provision";
        StateDirectoryMode = "0700";
        # adb keeps its client key in $HOME/.android/adbkey.
        Environment = "HOME=/var/lib/android-provision";
        TimeoutStartSec = "30min";
      };
      script = ''
        exec ${lib.getExe provisioner} ${verb} --manifest ${manifestFor name device}
      '';
    };

  deviceModule = {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to provision this device.";
      };

      host = mkOption {
        type = types.str;
        example = "192.0.2.50";
        description = "Device address. ADB over TCP must already be enabled on it.";
      };

      port = mkOption {
        type = types.port;
        default = 5555;
        description = "ADB over TCP port.";
      };

      abi = mkOption {
        type = types.str;
        default = "arm64-v8a";
        description = ''
          Device ABI, used to pick an APK variant.  Apps such as VLC publish one
          APK per ABI, so the package identifier alone is ambiguous.
        '';
      };

      packages = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "de.badaix.snapcast" ];
        description = "F-Droid package identifiers, pinned by apks.lock.json.";
      };

      github = mkOption {
        type = types.listOf (
          types.submodule {
            options = {
              repo = mkOption {
                type = types.str;
                example = "theothernt/AerialViews";
                description = "GitHub owner/repo.";
              };
              asset = mkOption {
                type = types.str;
                default = "*.apk";
                description = "Glob matching exactly one release asset.";
              };
            };
          }
        );
        default = [ ];
        description = "GitHub releases, pinned by apks.lock.json.";
      };

      obtainium = mkOption {
        type = types.listOf (
          types.submodule {
            options.url = mkOption {
              type = types.str;
              description = "App source URL for Obtainium to track.";
            };
          }
        );
        default = [ ];
        description = ''
          Apps handed to Obtainium, which owns their updates.  Nothing here is
          installed by the provisioner.
        '';
      };

      caCerts = mkOption {
        type = types.listOf types.path;
        default = [ ../../secrets/caddy-ca-root.crt ];
        description = ''
          CA certificates to install into the user trust store.  Defaults to the
          internal root Caddy issues from.  Setting this replaces the default
          rather than adding to it.

          Since Android 7 apps ignore user CAs unless they opt in, so this fixes
          the browser and not Kodi, Jellyfin or YouTube.
        '';
      };

      settings = mkOption {
        type = types.attrsOf (types.attrsOf (types.either types.str types.int));
        default = { };
        example = {
          global.screen_off_timeout = 600000;
        };
        description = "settings put values, by namespace (global, secure, system).";
      };

      allowDowngrade = mkOption {
        type = types.bool;
        default = false;
        description = "Replace an installed app that is newer than the lockfile.";
      };

      deviceOwner = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Set a Device Owner.  This can only succeed on a box with no
            configured accounts, in practice right after a factory reset, which
            the provisioner will never perform for you.
          '';
        };
        component = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "com.example.dpc/.AdminReceiver";
          description = "DPC admin receiver component.";
        };
      };
    };
  };
in
{
  options.androidDevices = mkOption {
    type = types.attrsOf (types.submodule deviceModule);
    default = { };
    description = "Android TV boxes to provision over ADB.";
  };

  config = lib.mkIf (devices != { }) {
    assertions =
      let
        # Group device names by "host:port" so a collision names every
        # device sharing it, not just that a collision exists.
        endpointGroups = lib.foldlAttrs (
          acc: name: d:
          let
            endpoint = "${d.host}:${toString d.port}";
          in
          acc // { ${endpoint} = (acc.${endpoint} or [ ]) ++ [ name ]; }
        ) { } devices;
      in
      lib.concatLists (
        lib.mapAttrsToList (
          endpoint: names:
          lib.optional (lib.length names > 1) {
            assertion = false;
            message = "androidDevices: ${lib.concatStringsSep " and " names} share the same host:port ${endpoint}.";
          }
        ) endpointGroups
      )
      ++ lib.mapAttrsToList (name: d: {
        assertion = !d.deviceOwner.enable || d.deviceOwner.component != null;
        message = "androidDevices.${name}: deviceOwner.enable needs deviceOwner.component.";
      }) devices
      ++ lib.concatLists (
        lib.mapAttrsToList (
          name: d:
          map (key: {
            assertion = lock ? ${key};
            message =
              "androidDevices.${name}: ${key} is not in pkgs/android-provision/apks.lock.json. "
              + "Run: nix run .#android-update";
          }) (d.packages ++ (map (g: g.repo) d.github))
        ) devices
      )
      # A key present in the lockfile might still lack a variant for this
      # device's abi (and no universal fallback). Checked only for keys the
      # previous assertion has already confirmed are in the lockfile, so
      # this never dereferences a missing lock entry.
      ++ lib.concatLists (
        lib.mapAttrsToList (
          name: d:
          map (
            key:
            let
              entry = lock.${key};
            in
            {
              assertion = entry.variants ? ${d.abi} || entry.variants ? universal;
              message =
                "androidDevices.${name}: ${entry.packageId} has no APK variant for abi \"${d.abi}\" "
                + "(available: ${lib.concatStringsSep ", " (lib.attrNames entry.variants)}).";
            }
          ) (lib.filter (key: lock ? ${key}) (d.packages ++ (map (g: g.repo) d.github)))
        ) devices
      );

    environment.systemPackages = [ provisioner ];

    systemd.services = lib.listToAttrs (
      lib.concatLists (
        lib.mapAttrsToList (name: d: [
          (unitFor name d false)
          (unitFor name d true)
        ]) devices
      )
    );
  };
}
