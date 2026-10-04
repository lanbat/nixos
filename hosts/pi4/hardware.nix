# hosts/pi4/hardware.nix
#
# Raspberry Pi 4 support from nixos-raspberrypi (added in flake.nix): the
# Raspberry Pi kernel and firmware, and the bootloader that manages the
# firmware partition. Like hosts/pi5/hardware.nix, it matches the
# nixos-raspberrypi installer image for the board (raspberry-pi-4), which the Pi
# is installed from the way docs/pi3-satellite.md describes for the Pi 3.
#
# The filesystems use the labels of that SD image (NIXOS_SD, FIRMWARE).
{ nixos-raspberrypi, ... }:
{
  imports = with nixos-raspberrypi.nixosModules; [
    raspberry-pi-4.base
    raspberry-pi-4.display-vc4
  ];

  # The generational firmware-partition bootloader, as on the installer image.
  boot.loader.raspberry-pi.bootloader = "kernel";

  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
    options = [
      "x-initrd.mount"
      "noatime"
    ];
  };

  fileSystems."/boot/firmware" = {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
    options = [
      "noatime"
      "noauto"
      "x-systemd.automount"
      "x-systemd.idle-timeout=1min"
    ];
  };

  nixpkgs.hostPlatform = "aarch64-linux";
}
