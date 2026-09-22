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

  failures = lib.filter (x: x != null) [
    (expectPass "example deploy with server in voiceRooms" baseDeploy)
    (expectPass "voiceRooms server role without lanbat-voice" voiceRoomOnServer)
    (expectThrow "bad voiceRooms host" badVoiceRooms)
    (expectThrow "storage-pi without drives" missingDrives)
    (expectThrow "multiple servers without primary override" twoServers)
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
