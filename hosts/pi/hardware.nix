# hosts/pi/hardware.nix
#
# Boot media of the Raspberry Pi 5. The nixos-hardware raspberry-pi-5 module
# (added in flake.nix) handles the device tree, kernel and firmware.
#
# The filesystems use the labels of the NixOS SD image (NIXOS_SD, FIRMWARE).
# The two storage drives are separate devices, unlocked after boot by
# modules/pi/clevis-unlock.nix.
{ modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "usbhid"
    "usb_storage"
    "vc4"
    "pcie_brcmstb"
  ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
    options = [ "noatime" ];
  };

  fileSystems."/boot/firmware" = {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
    options = [
      "nofail"
      "noauto"
    ];
  };

  nixpkgs.hostPlatform = "aarch64-linux";
}
