# plugins/stackchan/default.nix
#
# A Stack-chan robot as the face of a Linux Voice Assistant satellite, plugged
# into the Pi over USB (modules/pi/stackchan.nix, docs/stackchan.md). Enable it
# next to the voice plugin.
{
  name = "lanbat-stackchan";
  version = 2;
  roles = [
    "storage-pi"
    "voice-pi"
  ];
  modules = [
    ../../modules/pi/stackchan.nix
  ];
}
