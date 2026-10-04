# plugins/tv/default.nix
#
# TV box plugin for storage Pis: a Raspberry Pi based TV box, Kodi and
# EmulationStation on HDMI (modules/storage/tv-box.nix).
{
  name = "lanbat-tv";
  version = 2;
  roles = [
    "storage-pi"
  ];
  modules = [
    ../../modules/storage/tv-box.nix
  ];
}
