# plugins/tv/default.nix
#
# TV frontend plugin for storage Pis: Kodi and EmulationStation on HDMI.
{
  name = "lanbat-tv";
  version = 1;
  roles = [
    "storage-pi"
  ];
  modules = [
    ../../modules/pi/tv.nix
  ];
}
