# hosts/server/hardware-configuration.nix
#
# THIS FILE IS A TEMPLATE.
#
# Replace with the output of:
#   nixos-generate-config --root /mnt
# run on the actual server hardware during installation.
#
# The important parts this file must provide:
#   - boot.initrd.availableKernelModules  (SATA, USB, etc.)
#   - boot.kernelModules                  (kvm-intel or kvm-amd)
#   - fileSystems."/"                     (host root, plain ext4 on sda2)
#   - fileSystems."/boot"                 (EFI partition on sda1)
#   - swapDevices
#   - nixpkgs.hostPlatform.system = "x86_64-linux"
#
# Server partition layout (three-layer design):
#   sda1:  1 GiB  /boot        (EFI, vfat)   — systemd-boot
#   sda2: 50 GiB  /            (ext4)         — host layer, plain, no LUKS
#   sda3: 256 MiB (raw)        (control LUKS) — opened manually, see secure-layers.nix
#   sda4: rest    (raw)        (workload LUKS) — opened manually, see secure-layers.nix
#
# NOTE: sda3 and sda4 do NOT appear here — they are not mounted at boot.
# Their mount units live in modules/server/secure-layers.nix with noauto.
{ config, lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  # These modules are typical for the Dell OptiPlex micro form factor (SATA SSD).
  # nixos-generate-config will fill in the correct set for your hardware.
  boot.initrd.availableKernelModules = [
    "xhci_pci" "ahci" "usb_storage" "sd_mod" "sr_mod"
  ];
  boot.kernelModules = [ "kvm-intel" ]; # or "kvm-amd" for AMD

  # Host root — plain ext4, no LUKS.
  # The server boots without any passphrase; control and workload stay locked.
  fileSystems."/" = {
    device  = "/dev/disk/by-uuid/CHANGE_ME_ROOT_UUID";
    fsType  = "ext4";
    options = [ "noatime" ];
  };

  # EFI / boot partition.
  fileSystems."/boot" = {
    device  = "/dev/disk/by-uuid/CHANGE_ME_EFI_UUID";
    fsType  = "vfat";
    options = [ "umask=0077" ];
  };

  # No swap — add a swapfile or partition if needed.
  swapDevices = [];

  nixpkgs.hostPlatform.system = "x86_64-linux";
}
