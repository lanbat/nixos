# lib/overlay-providers.nix
#
# The overlay implementations, by name.
#
# Plain data rather than a NixOS module, for the same reason as
# plugins/services/registry.nix: lib/mkHost.nix has to choose one before any
# configuration exists to read. deployment.overlay.provider is static data in
# deploy.nix, so the choice is available at that point and no conditional
# import is needed.
{
  none = ../modules/overlay/none.nix;
}
