# hosts/pi/hardware-configuration.nix
#
# THIS FILE IS A TEMPLATE.
#
# Replace with the output of:
#   nixos-generate-config --show-hardware-config
# run on the Pi 5 after booting the NixOS AArch64 installer.
#
# The nixos-hardware raspberry-pi-5 module (imported in flake.nix) handles
# most of the Pi 5 device tree / kernel / firmware.  This file primarily
# provides the root filesystem declaration.
#
# IMPORTANT: The Pi 5 boots from microSD or USB.  The two 4 TB storage
# drives are SEPARATE devices — they are not the boot media.
# Boot media: /dev/mmcblk0 (microSD) or /dev/sda (USB) — NOT the 4 TB drives.
# Storage drives: /dev/sdb, /dev/sdc (or by-id — use by-id in production).
{ config, lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [
    "xhci_pci" "usbhid" "usb_storage" "vc4" "pcie_brcmstb"
  ];
  boot.kernelModules = [];

  # Boot filesystem (microSD).
  fileSystems."/" = {
    device = "/dev/disk/by-uuid/CHANGE_ME_PI_ROOT_UUID";
    fsType = "ext4";
    options = [ "noatime" ];
  };

  fileSystems."/boot/firmware" = {
    device = "/dev/disk/by-uuid/CHANGE_ME_PI_BOOT_UUID";
    fsType = "vfat";
  };

  swapDevices = [];

  nixpkgs.hostPlatform.system = "aarch64-linux";
}
