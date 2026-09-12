# tests/pi.nix
#
# VM test of the Raspberry Pi configuration (hosts/pi) with the example
# settings and test-only secrets. QEMU can't emulate a Raspberry Pi 5, so the
# test doesn't import hosts/pi/hardware.nix (firmware, bootloader and kernel
# from nixos-raspberrypi, added by flake.nix for the real Pi); those are only
# proven on the real card. It checks:
#   - the admin user, SSH and passwordless sudo,
#   - the static address and the NFS firewall rules,
#   - agenix decrypting the Telegraf token, and the services starting,
#   - the storage unlock services retrying without blocking boot.
#
# It must run on an aarch64 machine with KVM, such as the Pi itself:
#   nix build -L --eval-store auto --store ssh-ng://root@<pi> path:.#checks.aarch64-linux.pi
{ pkgs, agenix }:

pkgs.testers.runNixOSTest {
  name = "pi";

  node.pkgsReadOnly = false;

  nodes.pi =
    { lib, ... }:
    {
      imports = [
        agenix.nixosModules.default
        ../hosts/pi
        ../hosts/example-settings.nix
        ./lib/test-secrets.nix
      ];

      nixpkgs.config.allowUnfree = true;

      virtualisation.memorySize = 2048;

      # Test VMs take their clock from the host; the test framework turns
      # timesyncd off, while hosts/pi turns it on for the real Pi.
      services.timesyncd.enable = lib.mkForce false;

      # The test network: eth1 with the first node address.
      lanbat.piInterface = lib.mkForce "eth1";
      lanbat.piIp = lib.mkForce "192.168.1.2";

      # The frontend's graphics stack would compile for hours on the Pi, and
      # the test has no HDMI output to check it on.
      lanbat.piTvFrontend = lib.mkForce false;

      lanbat.testSecrets.telegraf-token = "TELEGRAF_INFLUXDB_TOKEN=test-influx-token\n";
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
        # The NFS server runs, and serves a drive only once it is mounted.
        pi.wait_for_unit("nfs-server.service")
        pi.succeed("exportfs -v | grep -q mountpoint")
        pi.fail("mountpoint -q /mnt/storage-a")
  '';
}
