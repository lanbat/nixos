# overlays/default.nix
#
# Overlay entry point.
#
# The unstable overlay is set up in flake.nix via specialArgs rather than
# here, because importing nixpkgs-unstable inside an overlay requires the
# input to be in scope — which it is not at overlay evaluation time.
#
# In any NixOS module, access unstable packages with:
#   pkgs.unstable.<name>
# provided you add the unstableOverlay in flake.nix (see the comment there).
#
# For now this file is a no-op overlay. Add local package overrides here
# as the repo grows.
final: prev: {
  # Example: override a package
  # somePackage = prev.somePackage.overrideAttrs (old: { ... });
}
