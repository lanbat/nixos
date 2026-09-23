# plugins/default.nix
#
# Registry of built-in lanbat plugins, exposed as lanbatPlugins in flake.nix.
{
  services = import ./services;
  tv = import ./tv;
  voice = import ./voice;
  android = import ./android;
  xiaomi-clock = import ./xiaomi-clock;
}
