# tests/postgresql.nix
#
# VM test of the two PostgreSQL instances:
#   - the always-on instance serves Grafana, Home Assistant's connection URL
#     and a password login while the workload layer is locked,
#   - the workload instance only starts after unlock-workload, with its data
#     on the LUKS volume, a password login and the vchord extension,
#   - lock-workload stops the workload instance but not the always-on one.
#
# Run with: nix build .#checks.x86_64-linux.postgresql
{ pkgs }:

pkgs.testers.runNixOSTest {
  name = "postgresql";

  nodes.machine =
    { config, pkgs, ... }:
    let
      alwaysOn = config.lanbat.postgresql.instances.always-on;
    in
    {
      imports = [
        ../modules/core/services.nix
        ../modules/core/database.nix
        ../modules/wiring/checks.nix
        ../modules/wiring/workload-gate.nix
        ../services/postgresql.nix
      ];

      virtualisation = {
        memorySize = 2048;
        # PostgreSQL's initdb doesn't fit in a few MiB next to the LUKS header.
        emptyDiskImages = [ 512 ];
        # Test VMs replace fileSystems with virtualisation.fileSystems.
        fileSystems = config.lanbat.layers.workloadFileSystems;
      };
      lanbat.layers.workloadDevice = "/dev/vdb";

      environment.etc = {
        "pg-test/authentik-env" = {
          text = "PASSWORD=authentik-secret\n";
          group = "postgres";
          mode = "0440";
        };
        "pg-test/immich-env" = {
          text = "POSTGRES_PASSWORD=immich-secret\n";
          group = "postgres";
          mode = "0440";
        };
      };

      lanbat.postgresql.databases = {
        hass.instance = "always-on";
        grafana.instance = "always-on";
        authentik = {
          instance = "always-on";
          passwordFile = "/etc/pg-test/authentik-env";
          passwordVariable = "PASSWORD";
        };
        immich = {
          instance = "workload";
          passwordFile = "/etc/pg-test/immich-env";
          extraSql = "CREATE EXTENSION IF NOT EXISTS vchord CASCADE;";
        };
      };

      users.users.hass = {
        isSystemUser = true;
        group = "hass";
      };
      users.groups.hass = { };

      # The database settings of services/grafana.nix.
      services.grafana = {
        enable = true;
        settings = {
          security.secret_key = "test-only-secret-key";
          database = {
            type = "postgres";
            host = "${alwaysOn.socket}:${toString alwaysOn.port}";
            name = "grafana";
            user = "grafana";
          };
        };
      };
      systemd.services.grafana = {
        after = [ alwaysOn.unit ];
        requires = [ alwaysOn.unit ];
      };

      environment.systemPackages = [
        pkgs.cryptsetup
        pkgs.curl
        # The driver and URL format Home Assistant's recorder uses.
        (pkgs.python3.withPackages (ps: [
          ps.sqlalchemy
          ps.psycopg2
        ]))
      ];
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    with subtest("always-on instance serves its databases while the workload layer is locked"):
        machine.wait_for_unit("postgresql-always-on-setup.service")
        machine.fail("systemctl is-active postgresql.service")
        machine.succeed(
            "sudo -u hass python3 -c \"import sqlalchemy; "
            "sqlalchemy.create_engine('postgresql://@/hass?host=/run/postgresql-always-on&port=5433').connect().close()\""
        )
        machine.succeed(
            "PGPASSWORD=authentik-secret psql -h 127.0.0.1 -p 5433 -U authentik -d authentik -c 'SELECT 1'"
        )
        machine.wait_for_unit("grafana.service")
        machine.wait_until_succeeds(
            "curl -sf http://127.0.0.1:3000/api/health | grep -q '\"database\": *\"ok\"'"
        )

    with subtest("create the workload volume"):
        machine.succeed(
            "printf secret | cryptsetup luksFormat --batch-mode --pbkdf pbkdf2 --pbkdf-force-iterations 1000 /dev/vdb",
            "printf secret | cryptsetup luksOpen /dev/vdb workload",
            "mkfs.ext4 -q /dev/mapper/workload",
            "cryptsetup luksClose workload",
        )

    with subtest("workload instance starts after unlock, on the encrypted layer"):
        machine.succeed("printf secret | unlock-workload")
        machine.wait_for_unit("postgresql.service")
        machine.wait_for_unit("postgresql-immich-init.service")
        machine.succeed("findmnt -n -o SOURCE /var/lib/postgresql | grep -q workload")
        machine.succeed(
            "PGPASSWORD=immich-secret psql -h 127.0.0.1 -p 5432 -U immich -d immich -tAc "
            "\"SELECT extname FROM pg_extension WHERE extname = 'vchord'\" | grep -q vchord"
        )

    with subtest("lock-workload stops only the workload instance"):
        machine.succeed("printf 'y\\n' | lock-workload")
        machine.fail("systemctl is-active postgresql.service")
        machine.succeed("systemctl is-active postgresql-always-on.service")
        machine.succeed("sudo -u grafana psql -h /run/postgresql-always-on -p 5433 -d grafana -c 'SELECT 1'")
  '';
}
