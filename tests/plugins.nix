# tests/plugins.nix
#
# Pure eval checks for the lanbat plugin contract.
{ lib, pkgs }:

let
  pluginLib = import ../lib/plugins.nix { inherit lib; };

  badPlugin = {
    name = "broken";
    version = 1;
    roles = [ "server" ];
    modules = [ ];
  };

  wrongRolePlugin = {
    name = "pi-only";
    version = 1;
    roles = [ "storage-pi" ];
    modules = [
      (
        { ... }:
        { }
      )
    ];
  };

  expectThrow =
    name: thunk:
    let
      result = builtins.tryEval thunk;
    in
    if result.success then
      "expected ${name} to throw, but it succeeded"
    else
      null;

  cases = [
    (expectThrow "empty modules" (pluginLib.validatePlugin badPlugin))
    (
      expectThrow "incompatible role" (
        pluginLib.resolvePlugins "server" [ wrongRolePlugin ]
      )
    )
  ];

  failures = lib.filter (x: x != null) cases;
in
pkgs.runCommand "plugins-check" { } ''
  if [ ${toString (lib.length failures)} -ne 0 ]; then
    echo "plugin contract checks failed:" >&2
    ${lib.concatStringsSep "\n" (map (msg: "echo \"  - ${msg}\" >&2") failures)}
    exit 1
  fi
  touch $out
''
