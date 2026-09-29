# tests/validate-deploy.nix
{ lib, pkgs }:

let
  validate = import ../lib/validate-deploy.nix { inherit lib; };

  lanbatPlugins = import ../plugins;

  baseDeploy = import ../deployments/example/deploy.nix {
    inputs = {
      self = { inherit lanbatPlugins; };
    };
  };

  expectThrow =
    name: deploy:
    let
      result = builtins.tryEval (
        validate.validateDeploy {
          profileName = "test";
          deploy = deploy;
        }
      );
    in
    if result.success then "expected ${name} to throw" else null;

  expectPass =
    name: deploy:
    let
      result = builtins.tryEval (
        validate.validateDeploy {
          profileName = "test";
          deploy = deploy;
        }
      );
    in
    if result.success then null else "expected ${name} to pass";

  badVoiceRooms = baseDeploy // {
    deployment = baseDeploy.deployment // {
      voiceRooms = {
        "Office" = "no-such-host";
      };
    };
  };

  missingDrives = baseDeploy // {
    hosts = baseDeploy.hosts // {
      pi-storage = baseDeploy.hosts.pi-storage // {
        storage = {
          drives = { };
        };
      };
    };
  };

  withDrives =
    drives:
    baseDeploy
    // {
      hosts = baseDeploy.hosts // {
        pi-storage = baseDeploy.hosts.pi-storage // {
          storage = { inherit drives; };
        };
      };
    };

  twoServers = baseDeploy // {
    hosts = baseDeploy.hosts // {
      server-b = baseDeploy.hosts.server;
    };
  };

  voiceRoomOnServer = baseDeploy // {
    deployment = baseDeploy.deployment // {
      voiceRooms = {
        "Office" = "server";
      };
    };
  };

  withRoleModules =
    roleModules:
    baseDeploy
    // {
      hosts = baseDeploy.hosts // {
        server = baseDeploy.hosts.server // {
          inherit roleModules;
        };
      };
    };

  rolesLib = import ../lib/roles.nix { inherit lib; };

  # Markers stand in for modules: resolveRoleModules never looks inside one.
  serverWithoutCaddy = rolesLib.resolveRoleModules rolesLib.builtinRoles "server" {
    wiring-caddy = null;
    backups = "my-backups";
    disk = [
      "disk-a"
      "disk-b"
    ];
  };
  bundledServer = rolesLib.getRoleModules "server";

  # A host that takes a role one of its plugins declares.
  nasPlugin = {
    name = "nas";
    version = 2;
    roles = [ "nas" ];
    hostRoles.nas = {
      modules = [
        {
          name = "role";
          module = { };
        }
      ];
      requirements = host: lib.optional (!(host ? nasDisk)) "nas role requires nasDisk";
    };
  };
  withNas =
    entry:
    baseDeploy
    // {
      hosts = baseDeploy.hosts // {
        nas = baseDeploy.hosts.pi-storage // entry;
      };
    };
  nasHost = {
    role = "nas";
    plugins = [ nasPlugin ];
    nasDisk = "example-nas-disk";
  };

  failures = lib.filter (x: x != null) [
    (expectPass "example deploy with server in voiceRooms" baseDeploy)
    (expectPass "voiceRooms server role without lanbat-voice" voiceRoomOnServer)
    (expectThrow "bad voiceRooms host" badVoiceRooms)
    (expectThrow "storage-pi without drives" missingDrives)
    (expectPass "storage-pi with one drive" (withDrives {
      data = "example-storage-1";
    }))
    (expectPass "storage-pi with three drives" (withDrives {
      a = "example-storage-a";
      b = "example-storage-b";
      c = "example-storage-c";
    }))
    (expectThrow "a drive key that is not a safe unit name" (withDrives {
      a = "example-storage-a";
      "b-2" = "example-storage-b";
    }))
    (expectThrow "a drive with an empty by-id name" (withDrives {
      a = "";
    }))
    (expectThrow "multiple servers without primary override" twoServers)
    (expectPass "a role a host's plugin declares" (withNas nasHost))
    (expectThrow "a plugin role whose requirements are not met" (
      withNas (builtins.removeAttrs nasHost [ "nasDisk" ])
    ))
    (expectThrow "a plugin role without the plugin that declares it" (
      withNas (nasHost // { plugins = [ ]; })
    ))
    (expectThrow "an unknown role" (withNas (nasHost // { role = "no-such-role"; })))
    (expectPass "roleModules dropping a bundled module" (withRoleModules {
      wiring-caddy = null;
    }))
    (expectThrow "roleModules naming a module the role does not bundle" (withRoleModules {
      no-such-module = null;
    }))
    (
      if
        !(lib.elem ../modules/wiring/caddy.nix serverWithoutCaddy)
        && lib.elem ../modules/wiring/caddy.nix bundledServer
      then
        null
      else
        "roleModules: wiring-caddy = null must drop modules/wiring/caddy.nix"
    )
    (
      let
        # The bundled order with the overrides in place of what they replace.
        expected = lib.concatMap (
          m:
          if m == ../modules/wiring/caddy.nix then
            [ ]
          else if m == ../modules/server/backups.nix then
            [ "my-backups" ]
          else if m == ../hosts/server/disk.nix then
            [
              "disk-a"
              "disk-b"
            ]
          else
            [ m ]
        ) bundledServer;
      in
      if serverWithoutCaddy == expected then
        null
      else
        "roleModules: a replacement must take the place of the module it replaces"
    )
  ];
in
pkgs.runCommand "validate-deploy-check" { } ''
  if [ ${toString (lib.length failures)} -ne 0 ]; then
    echo "validate-deploy tests failed:" >&2
    ${lib.concatStringsSep "\n" (map (m: "echo \"  - ${m}\" >&2") failures)}
    exit 1
  fi
  touch $out
''
