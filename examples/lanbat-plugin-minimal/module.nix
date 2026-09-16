# module.nix
#
# Harmless marker file — proves the plugin module was imported.
{ ... }:
{
  environment.etc."lanbat-plugin-example".text = "lanbat-plugin-minimal example\n";
}
