# tests/settings-guard.nix
#
# Deployment-specific lanbat options must not have defaults. Missing values
# should fail evaluation instead of deploying placeholder IPs or domains.
{ lib, pkgs }:

let
  eval = lib.evalModules {
    modules = [ ../modules/core/settings.nix ];
  };

  allowedWithDefault = [
    "haLlm"
    "voiceSatelliteServer"
    "voiceRooms.server"
    "voiceRooms.pi"
  ];

  collectOptions =
    opts: path:
    lib.concatLists (
      lib.map (
        name:
        let
          v = opts.${name};
          childPath = path ++ [ name ];
          childName = lib.concatStringsSep "." childPath;
        in
        if v ? _type && v._type == "option" then
          [
            {
              name = childName;
              hasDefault = v ? default;
            }
          ]
        else
          collectOptions v childPath
      ) (lib.attrNames opts)
    );

  offending = lib.filter (o: o.hasDefault && !(lib.elem o.name allowedWithDefault)) (
    collectOptions eval.options.lanbat [ ]
  );
in
pkgs.runCommand "settings-guard-check" { } ''
  if [ ${toString (lib.length offending)} -ne 0 ]; then
    echo "lanbat options must not have defaults (except optional features):" >&2
    ${lib.concatStringsSep "\n" (map (o: "echo \"  - ${o.name}\" >&2") offending)}
    exit 1
  fi
  touch $out
''
