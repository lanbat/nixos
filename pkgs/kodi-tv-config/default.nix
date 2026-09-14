{
  lib,
  stdenv,
}:

stdenv.mkDerivation {
  pname = "kodi-tv-config";
  version = "1.0";

  src = ./.;

  installPhase = ''
    install -Dm644 advancedsettings.xml $out/advancedsettings.xml
    install -Dm644 sources.xml $out/sources.xml
    install -Dm644 guisettings.xml $out/guisettings.xml
    install -Dm644 keymaps/tv.xml $out/keymaps/tv.xml
    install -Dm644 addon-data/plugin.video.youtube/settings.xml \
      $out/addon-data/plugin.video.youtube/settings.xml
  '';

  meta.description = "Seeded Kodi userdata for the Pi TV frontend";
}
