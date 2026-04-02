# pkgs/launcher/default.nix
#
# Nix package for the homelab TV launcher.
# Wraps the Python/GTK3 script with all dependencies.
{ pkgs ? import <nixpkgs> {} }:

pkgs.stdenv.mkDerivation {
  pname   = "homelab-launcher";
  version = "1.0.0";

  src = ./.;

  buildInputs = [
    (pkgs.python3.withPackages (ps: [
      ps.pygobject3
    ]))
  ];

  nativeBuildInputs = [ pkgs.makeWrapper ];

  propagatedBuildInputs = with pkgs; [
    gtk3
    gobject-introspection
  ];

  installPhase = ''
    install -Dm755 ${./launcher.py} $out/bin/homelab-launcher

    wrapProgram $out/bin/homelab-launcher \
      --prefix GI_TYPELIB_PATH : "${pkgs.gtk3}/lib/girepository-1.0:${pkgs.pango}/lib/girepository-1.0" \
      --prefix LD_LIBRARY_PATH : "${pkgs.gtk3}/lib:${pkgs.glib}/lib" \
      --set PYTHONPATH "${pkgs.python3.withPackages (ps: [ ps.pygobject3 ])}/${pkgs.python3.sitePackages}"
  '';

  meta = {
    description = "Full-screen TV launcher for Kodi and RetroArch";
    platforms   = [ "aarch64-linux" ];
  };
}
