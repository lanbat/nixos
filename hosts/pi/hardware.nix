# hosts/pi/hardware.nix
#
# Raspberry Pi 5 support from nixos-raspberrypi (added in flake.nix): the
# Raspberry Pi kernel and firmware, and the bootloader that manages the
# firmware partition. This matches the nixos-raspberrypi Pi 5 installer image
# the Pi is installed from (docs/deployment-checklist.md, Phase 2).
#
# The filesystems use the labels of that SD image (NIXOS_SD, FIRMWARE). The
# two NVMe storage drives are separate devices, unlocked after boot by
# modules/pi/clevis-unlock.nix.
{ nixos-raspberrypi, ... }:
{
  imports = with nixos-raspberrypi.nixosModules; [
    raspberry-pi-5.base
    # Not raspberry-pi-5.page-size-16k: that optional memory optimization
    # rebuilds jemalloc for the kernel's 16k pages, and with it rustc and much
    # of the system, which then compiles on the Pi instead of coming from
    # cache.nixos.org. nixpkgs' jemalloc already works with 16k pages on aarch64.
    # HDMI output for the TV frontend.
    raspberry-pi-5.display-vc4
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
