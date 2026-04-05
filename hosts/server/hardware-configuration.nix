{ config, lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "usb_storage" "usbhid" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # Host root — plain ext4, no LUKS.
  # The server boots without any passphrase; control and workload stay locked.
  fileSystems."/" = {
    device = "/dev/disk/by-uuid/cebb3e92-3190-4b2c-abcf-d51618f67f51";
    fsType = "ext4";
  };

  # EFI / boot partition.
  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/5743-F5C5";
    fsType = "vfat";
    options = [ "fmask=0022" "dmask=0022" ];
  };

  # sda3 (control LUKS) and sda4 (workload LUKS) are not mounted at boot.
  # Their mount units live in modules/server/secure-layers.nix with noauto.

  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
