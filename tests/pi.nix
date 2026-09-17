# tests/pi.nix
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
  name = "pi";

  node.pkgsReadOnly = false;

  nodes.pi =
    { ... }:
    {
      imports = [
        fixture.piStorageConfig
      ];
    };

  testScript = ''
    pi.start()
    pi.wait_for_unit("multi-user.target")

    with subtest("admin user, SSH and passwordless sudo"):
        pi.wait_for_unit("sshd.service")
        pi.succeed("id admin")
        pi.succeed("sudo -u admin sudo -n true")

    with subtest("static address and NFS firewall rules"):
        pi.succeed("ip -4 addr show eth1 | grep -q 192.168.1.2")
        pi.succeed("iptables -S | grep -q -- '--dport 2049'")

    with subtest("agenix decrypts the Telegraf token and services start"):
        pi.succeed("test -s /run/agenix/telegraf-token")
        pi.wait_for_unit("telegraf.service")
        pi.wait_for_unit("snapclient.service")

    with subtest("storage unlock retries without blocking boot or NFS"):
        pi.wait_until_succeeds(
            "systemctl show storage-a-unlock.service -p ActiveState --value | grep -qE '^(activating|failed)$'",
            timeout=120,
        )
        pi.wait_for_unit("nfs-server.service")
        pi.succeed("exportfs -v | grep -q mountpoint")
        pi.fail("mountpoint -q /mnt/storage-a")
  '';
}
