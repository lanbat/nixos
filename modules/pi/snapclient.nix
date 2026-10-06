# modules/pi/snapclient.nix
#
# The Pi roles' Snapcast client (lib/roles.nix bundles this as "snapclient";
# roleModules.snapclient = null drops it). The client itself is
# modules/core/snapclient.nix, which every host imports.
{
  lanbat.snapclient.enable = true;
}
