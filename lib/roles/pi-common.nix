# lib/roles/pi-common.nix
#
# What the Raspberry Pi roles (storage-pi, voice-pi) share on top of
# lib/roles/common.nix, merged in the same way (see there). The Pi's hardware
# itself (kernel, firmware, filesystems) is not here: lib/mkHost.nix adds it by
# platform.
{ ... }:

{
  services.timesyncd.enable = true;

  boot.loader.grub.enable = false;
}
