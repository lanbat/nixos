# tests/plugins.nix
#
# Pure eval checks for the lanbat plugin contract, including the service
# selection that lets a host import only some of what a plugin offers.
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
      ({ ... }: { })
    ];
  };

  # resolvePlugins never looks inside a module, so a marker string stands in for
  # one and makes the resolved list easy to compare.
  offering = name: services: {
    inherit name services;
    version = 1;
    roles = [ "server" ];
    modules = lib.attrValues services;
  };

  media = offering "media" {
    jellyfin = "jellyfin-module";
    immich = "immich-module";
  };

  infra = offering "infra" {
    caddy = "caddy-module";
  };

  # No services attribute: all-or-nothing, so a selection must not shrink it.
  monolith = {
    name = "monolith";
    version = 1;
    roles = [ "server" ];
    modules = [
      "monolith-a"
      "monolith-b"
    ];
  };

  clashing = offering "other-media" {
    jellyfin = "a-different-jellyfin";
  };

  resolve = pluginLib.resolvePlugins "server";

  expectThrow =
    name: thunk:
    if (builtins.tryEval thunk).success then "expected ${name} to throw, but it succeeded" else null;

  expect = name: cond: if cond then null else "FAIL: ${name}";

  sorted = lib.sort (a: b: a < b);

  cases = [
    (expectThrow "empty modules" (pluginLib.validatePlugin badPlugin))
    (expectThrow "incompatible role" (resolve [ wrongRolePlugin ] [ ]))

    (expect "an empty selection takes everything a plugin offers" (
      sorted (resolve [ media ] [ ]) == [
        "immich-module"
        "jellyfin-module"
      ]
    ))

    (expect "a selection takes only the named services" (
      resolve [ media ] [ "jellyfin" ] == [ "jellyfin-module" ]
    ))

    (expect "a selection spanning two plugins takes from both" (
      sorted (
        resolve
          [ media infra ]
          [
            "caddy"
            "immich"
          ]
      ) == [
        "caddy-module"
        "immich-module"
      ]
    ))

    (expect "a plugin with no services attribute ignores a selection" (
      sorted (resolve [ media monolith ] [ "jellyfin" ]) == [
        "jellyfin-module"
        "monolith-a"
        "monolith-b"
      ]
    ))

    (expectThrow "a service no enabled plugin offers" (resolve [ media ] [ "nextcloud" ]))

    (expectThrow "two plugins offering the same service" (resolve [ media clashing ] [ "jellyfin" ]))

    (expect "offeredServices merges what every plugin offers" (
      sorted (
        lib.attrNames (
          pluginLib.offeredServices [
            media
            infra
          ]
        )
      ) == [
        "caddy"
        "immich"
        "jellyfin"
      ]
    ))
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
