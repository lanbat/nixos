# tests/settings-schema.nix
#
# Checks the settings contract of modules/core/services.nix: a service that
# declares its settings keys accepts only those (modules/wiring/checks.nix
# names the service and the key it rejects), and a service that declares none
# keeps its settings freeform. Pure evaluation.
{ lib, pkgs }:

let
  evalHost =
    modules:
    let
      system = lib.nixosSystem {
        modules = [
          ../modules/core/services.nix
          ../modules/wiring/accounts.nix
          {
            boot.isContainer = true;
            nixpkgs.hostPlatform = "x86_64-linux";
            system.stateVersion = "25.11";
          }
        ]
        ++ modules;
      };
      checks = import ../modules/wiring/checks.nix {
        inherit lib;
        inherit (system) config;
      };
    in
    {
      inherit (system.config.lanbat) services;
      messages = map (a: a.message) (lib.filter (a: !a.assertion) checks.assertions);
    };

  # A schema declared the documented way, through lanbat.settingsSchema.
  schema.lanbat.settingsSchema.demo.options = {
    retainDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 7;
    };
    cameras = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
    };
  };

  withSchema = settings: extra: {
    imports = [ schema ];
    lanbat.services.demo = {
      inherit settings;
    }
    // extra;
  };

  # The long way, which needs nothing from core: a service module re-declares
  # lanbat.services with a schema for its own name only.
  byName = {
    options.lanbat.services = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options.settings = lib.mkOption {
              type = lib.types.submodule (
                lib.optionalAttrs (name == "strict") {
                  options.mode = lib.mkOption {
                    type = lib.types.enum [
                      "fast"
                      "slow"
                    ];
                    default = "fast";
                  };
                }
              );
            };
          }
        )
      );
    };
  };

  expectMessages =
    name: modules: fragments:
    let
      inherit (evalHost modules) messages;
      missing = lib.filter (f: !lib.any (lib.hasInfix f) messages) fragments;
      unexpected = fragments == [ ] && messages != [ ];
    in
    if missing != [ ] || unexpected then
      "${name}: expected ${builtins.toJSON fragments}, got ${builtins.toJSON messages}"
    else
      null;

  expect = name: cond: if cond then null else name;

  expectThrow =
    name: thunk: if (builtins.tryEval (builtins.deepSeq thunk thunk)).success then name else null;

  cases = [
    (expectMessages "a service without a schema accepts any key"
      [
        { lanbat.services.demo.settings.anything.goes = 1; }
      ]
      [ ]
    )

    (expect "a service without a schema is freeform" (
      (evalHost [ { lanbat.services.demo.settings.x = 1; } ]).services.demo.settingsFreeform
    ))

    (expectMessages "a declared key passes" [ (withSchema { retainDays = 30; } { }) ] [ ])

    (expect "a service with a schema lists its keys" (
      (evalHost [ (withSchema { } { }) ]).services.demo.settingsKeys == [
        "cameras"
        "retainDays"
      ]
    ))

    (expectMessages "an undeclared key is rejected, naming service and key"
      [ (withSchema { retainDay = 30; } { }) ]
      [
        "demo has no setting \"retainDay\""
        "it declares cameras, retainDays"
      ]
    )

    (expectMessages "each undeclared key is named"
      [
        (withSchema {
          a = 1;
          b = 2;
        } { })
      ]
      [
        "demo has no setting \"a\""
        "demo has no setting \"b\""
      ]
    )

    (expectMessages "settingsFreeform passes undeclared keys through"
      [
        (withSchema { passthrough = true; } { settingsFreeform = true; })
      ]
      [ ]
    )

    (expect "a freeform key still reaches settings" (
      (evalHost [ (withSchema { passthrough = true; } { settingsFreeform = true; }) ])
      .services.demo.settings.passthrough
    ))

    (expect "a module default is overridden without mkForce" (
      (evalHost [
        (withSchema { retainDays = lib.mkDefault 14; } { })
        { lanbat.services.demo.settings.retainDays = 60; }
      ]).services.demo.settings.retainDays == 60
    ))

    (expectThrow "a declared key is type checked" (
      (evalHost [ (withSchema { retainDays = "thirty"; } { }) ]).services.demo.settings.retainDays
    ))

    (expectMessages "a schema declared by name applies to that service only"
      [
        byName
        {
          lanbat.services.strict.settings.mdoe = "slow";
          lanbat.services.loose.settings.whatever = 1;
        }
      ]
      [ "strict has no setting \"mdoe\"; it declares mode" ]
    )

    (expect "a schema declared by name leaves other services freeform" (
      let
        inherit
          (evalHost [
            byName
            { lanbat.services.loose.settings.whatever = 1; }
          ])
          services
          ;
      in
      services.loose.settingsFreeform && services.loose.settingsKeys == [ ]
    ))
  ];

  failures = lib.filter (x: x != null) cases;
in
pkgs.runCommand "settings-schema-check" { } ''
  if [ ${toString (lib.length failures)} -ne 0 ]; then
    echo "settings schema checks failed:" >&2
    ${lib.concatStringsSep "\n" (map (msg: "echo ${lib.escapeShellArg "  - ${msg}"} >&2") failures)}
    exit 1
  fi
  touch $out
''
