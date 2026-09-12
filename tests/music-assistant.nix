# tests/music-assistant.nix
#
# VM smoke test: Music Assistant starts and serves its web UI on port 8095.
# Modeled on upstream nixpkgs nixos/tests/music-assistant.nix.
#
# Run with: nix build .#checks.x86_64-linux.music-assistant
{ pkgs }:

pkgs.testers.runNixOSTest {
  name = "music-assistant";

  nodes.machine = {
    services.music-assistant.enable = true;
  };

  testScript = ''
    machine.wait_for_unit("music-assistant.service")
    machine.wait_until_succeeds("curl --fail http://localhost:8095")
  '';
}
