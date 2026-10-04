# tests/storage-pi.nix
#
# VM test of the storage-pi role built through mkHost and the test deploy fixture.
{
  pkgs,
  agenix,
  inputs,
  nixpkgs,
  nixos-raspberrypi,
  disko,
}:

let
  fixture = import ./lib/mk-host-fixture.nix {
    inherit
      pkgs
      agenix
      inputs
      nixpkgs
      nixos-raspberrypi
      disko
      ;
  };
in
pkgs.testers.runNixOSTest {
  name = "storage-pi";

  node.pkgsReadOnly = false;

  nodes.storage-pi =
    { ... }:
    {
      imports = [
        fixture.default.nodes.pi-storage
      ];
    };

  testScript = ''
    storage_pi.start()
    storage_pi.wait_for_unit("multi-user.target")

    with subtest("admin user, SSH and passwordless sudo"):
        storage_pi.wait_for_unit("sshd.service")
        storage_pi.succeed("id admin")
        storage_pi.succeed("sudo -u admin sudo -n true")

    with subtest("static address and NFS firewall rules"):
        storage_pi.succeed("ip -4 addr show eth1 | grep -q 192.168.1.2")
        storage_pi.succeed("iptables -S | grep -q -- '--dport 2049'")

    with subtest("agenix decrypts the Telegraf token and services start"):
        storage_pi.succeed("test -s /run/agenix/telegraf-token")
        storage_pi.wait_for_unit("telegraf.service")
        storage_pi.wait_for_unit("snapclient.service")

    with subtest("storage unlock retries without blocking boot or NFS"):
        storage_pi.wait_until_succeeds(
            "systemctl show storage-a-unlock.service -p ActiveState --value | grep -qE '^(activating|failed)$'",
            timeout=120,
        )
        storage_pi.wait_for_unit("nfs-server.service")
        storage_pi.succeed("exportfs -v | grep -q mountpoint")
        storage_pi.fail("mountpoint -q /mnt/storage-a")
  '';
}
