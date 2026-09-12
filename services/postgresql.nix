# services/postgresql.nix
#
# Shared PostgreSQL instance.
#
# Services add their database with lanbat.postgresql.databases.<name>: the
# database and an owner of the same name are created, and
# postgresql-<name>-init sets the owner's password from the service's secret
# (containers log in over TCP with a password). Nextcloud uses peer
# authentication through its own module (database.createLocally).
#
# vectorchord (Immich's vector search) must be preloaded.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  databases = config.lanbat.postgresql.databases;
  psql = "${config.services.postgresql.package}/bin/psql";
in
{
  options.lanbat.postgresql.databases = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          passwordFile = lib.mkOption {
            type = lib.types.str;
            description = "Environment file (readable by the postgres group) that defines the password variable.";
          };
          passwordVariable = lib.mkOption {
            type = lib.types.str;
            default = "POSTGRES_PASSWORD";
            description = "Variable in passwordFile that holds the password.";
          };
          extraSql = lib.mkOption {
            type = lib.types.lines;
            default = "";
            description = "SQL to run in the database after setting the password, e.g. CREATE EXTENSION.";
          };
        };
      }
    );
    default = { };
    description = "Databases on the shared instance, each owned by a user of the same name.";
  };

  config = {
    lanbat.services.postgresql.extraPorts = [ 5432 ];

    services.postgresql = {
      enable = true;
      package = pkgs.postgresql_16;
      extensions =
        ps: with ps; [
          pgvector
          vectorchord
        ];

      settings = {
        # Containers reach it through --network=host.
        listen_addresses = lib.mkForce "127.0.0.1";
        shared_preload_libraries = "vchord.so";
        # Authentik (Django + Celery), Nextcloud, Immich and Bitmagnet exhaust the default 100.
        max_connections = 200;
      };

      authentication = lib.mkForce ''
        # TYPE  DATABASE        USER            ADDRESS           METHOD
        local   all             all                               peer
        host    all             all             127.0.0.1/32      scram-sha-256
      '';

      ensureDatabases = lib.attrNames databases;
      ensureUsers = map (name: {
        inherit name;
        ensureDBOwnership = true;
      }) (lib.attrNames databases);
    };

    systemd.services = lib.mapAttrs' (
      name: db:
      lib.nameValuePair "postgresql-${name}-init" {
        description = "Set the ${name} PostgreSQL password";
        after = [
          "postgresql.service"
          "postgresql-setup.service"
        ];
        wantedBy = [ "postgresql.service" ];
        unitConfig.ConditionPathExists = db.passwordFile;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "postgres";
          ExecStart = pkgs.writeShellScript "postgresql-${name}-init" ''
            set -euo pipefail
            ${db.passwordVariable}=""
            source ${db.passwordFile}
            ${psql} -c "ALTER USER ${name} WITH ENCRYPTED PASSWORD '${"$" + db.passwordVariable}';"
            ${lib.optionalString (db.extraSql != "") "${psql} -d ${name} -c ${lib.escapeShellArg db.extraSql}"}
          '';
        };
      }
    ) databases;
  };
}
