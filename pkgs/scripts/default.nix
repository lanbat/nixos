# pkgs/scripts/default.nix
#
# Helper scripts as Nix packages.
# The domain is substituted at build time so scripts never hardcode it.
#
# Usage in a NixOS module:
#   environment.systemPackages = [
#     (pkgs.callPackage ../../pkgs/scripts { inherit (config.lanbat) domain; })
#   ];
{ pkgs ? import <nixpkgs> {}
, domain ? "home.example.com"
}:

let
  mkScript = name: src: pkgs.writeShellScriptBin name (
    # Substitute @DOMAIN@ placeholder at build time.
    builtins.replaceStrings [ "@DOMAIN@" ] [ domain ]
      (builtins.readFile src)
  );
in
pkgs.symlinkJoin {
  name    = "homelab-scripts";
  paths   = [
    (mkScript "quota-setup"     ./quota-setup.sh)
    (mkScript "quota-report"    ./quota-report.sh)
    (mkScript "backup-server"   ./backup-server.sh)
    (mkScript "trust-ca-linux"  ./trust-ca-linux.sh)
    (mkScript "trust-ca-macos"  ./trust-ca-macos.sh)
  ];
}
