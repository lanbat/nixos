# modules/core/database.nix
#
# The database contract.
#
# A service asks for a database by declaring lanbat.postgresql.databases.<name>.
# A provider — services/postgresql.nix for the built-in one — answers by
# advertising its instances in lanbat.postgresql.instances.
#
# The contract lives here, in a module every host imports, rather than in the
# provider, so that asking for a database does not require the provider's file
# to have been imported. Before this split a host that ran Authentik but not
# postgresql failed to evaluate with "option lanbat.postgresql does not exist",
# which is a confusing way to say that nothing on this host serves databases.
#
# Instance names are not fixed here. The built-in provider offers "workload"
# and "always-on", one per storage tier, but a deployment may replace it with a
# provider that offers different ones.
{
  config,
  lib,
  ...
}:

let
  inherit (lib) mkOption types;
  cfg = config.lanbat.postgresql;
in
{
  options.lanbat.postgresql = {
    databases = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            instance = mkOption {
              type = types.str;
              example = "workload";
              description = ''
                Which instance holds the database, by name. Use the instance
                matching the consuming service's tier: a workload-gated
                service's data belongs on the workload instance.
              '';
            };
            passwordFile = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Environment file (readable by the postgres group) defining the password for TCP logins.";
            };
            passwordVariable = mkOption {
              type = types.str;
              default = "POSTGRES_PASSWORD";
              description = "Variable in passwordFile that holds the password.";
            };
            extraSql = mkOption {
              type = types.lines;
              default = "";
              description = "SQL to run in the database after setup, e.g. CREATE EXTENSION.";
            };
          };
        }
      );
      default = { };
      description = "Databases, each owned by a role of the same name.";
    };

    instances = mkOption {
      type = types.attrsOf (types.attrsOf types.anything);
      default = { };
      description = ''
        Connection details each provider advertises, and the unit consumers
        order after. Empty when this host serves no databases.
      '';
    };

    instance = mkOption {
      type = types.functionTo (types.attrsOf types.anything);
      internal = true;
      readOnly = true;
      description = ''
        Connection details of one instance, by name.

        A consumer reads this rather than indexing instances directly. Both
        fail on a host with no provider, but this one says which instance was
        wanted and what to do about it, instead of reporting a missing
        attribute from somewhere inside a systemd unit definition.
      '';
    };
  };

  config.lanbat.postgresql.instance =
    name:
    cfg.instances.${name} or (throw (
      "lanbat.postgresql: a service on this host wants database instance"
      + " \"${name}\", but no database provider runs here."
      + " Add one to this host's services, or drop the service that wants it."
    ));

  config.assertions = [
    {
      assertion = cfg.databases == { } || cfg.instances != { };
      message =
        "lanbat.postgresql.databases asks for "
        + lib.concatStringsSep ", " (lib.attrNames cfg.databases)
        + ", but no database provider runs on this host. Add one to this host's"
        + " services, or drop the services that want a database.";
    }
  ]
  ++ lib.optionals (cfg.instances != { }) (
    lib.mapAttrsToList (name: db: {
      assertion = cfg.instances ? ${db.instance};
      message =
        "lanbat.postgresql.databases.${name} wants instance \"${db.instance}\","
        + " which no provider offers. Available: "
        + lib.concatStringsSep ", " (lib.attrNames cfg.instances)
        + ".";
    }) cfg.databases
  );
}
