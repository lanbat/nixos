# hosts/server/hardware-configuration.nix
#
# THIS FILE IS A TEMPLATE.
#
# Replace this file with the output of:
#   nixos-generate-config --show-hardware-config
# run on the actual server hardware after booting the NixOS installer.
#
# The important parts this file must provide:
#   - boot.initrd.availableKernelModules  (NVMe, SATA, USB, etc.)
#   - boot.kernelModules                  (kvm-intel or kvm-amd)
#   - fileSystems."/"                     (pointing at the LUKS-unlocked volume)
#   - fileSystems."/boot"                 (EFI partition)
#   - swapDevices                         (if any)
#   - nixpkgs.hostPlatform.system = "x86_64-linux"
#
# EXAMPLE (edit before use):
{ config, lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [
    "nvme" "xhci_pci" "ahci" "usb_storage" "sd_mod"
    # Add "cryptd" if hardware crypto offload is needed.
  ];
  boot.kernelModules = [ "kvm-intel" ]; # or "kvm-amd"

  # Root filesystem — inside the LUKS volume declared in default.nix.
  # Adjust /dev/mapper/... and UUID to match your setup.
  fileSystems."/" = {
    device  = "/dev/mapper/cryptroot";
    fsType  = "ext4";  # or btrfs
    options = [ "noatime" ];
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/CHANGE_ME_EFI_UUID";
    fsType = "vfat";
  };

  swapDevices = [];

  nixpkgs.hostPlatform.system = "x86_64-linux";
}
