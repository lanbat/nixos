# modules/core/default.nix
#
# Imported by every host: settings, the service interface, shared system
# configuration, and the wiring that applies on any host.
{
  imports = [
    ./settings.nix
    ./host-context.nix
    ./services.nix
    ./base.nix
    ./gc.nix
    ./auto-upgrade.nix
    ./ssh.nix
    ./users.nix
    ./human-users.nix
    ./voice-satellite.nix
    ../wiring/accounts.nix
    ../wiring/secrets.nix
    ../wiring/checks.nix
  ];
}
