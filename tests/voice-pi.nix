# tests/voice-pi.nix
#
# VM test of the voice-pi role built through mkHost and the test deploy fixture.
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
  name = "voice-pi";

  node.pkgsReadOnly = false;

  nodes.voice-pi =
    { lib, ... }:
    {
      imports = [
        fixture.voicePiConfig
        (
          { ... }:
          {
            virtualisation.memorySize = lib.mkForce 1024;
          }
        )
      ];
    };

  testScript = ''
    voice_pi.start()
    voice_pi.wait_for_unit("multi-user.target")

    with subtest("admin user and SSH"):
        voice_pi.wait_for_unit("sshd.service")
        voice_pi.succeed("id admin")

    with subtest("Wyoming satellite unit"):
        voice_pi.succeed("systemctl cat wyoming-satellite.service >/dev/null")

    with subtest("firewall restricts port 10700 to server IP"):
        voice_pi.succeed("iptables -S | grep -q -- '--dport 10700'")
        voice_pi.succeed("iptables -S | grep -q '10700.*192.0.2.10'")
  '';
}
