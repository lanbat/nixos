# hosts/pi3/hardware.nix
#
# Raspberry Pi 3 (B or B+), booting from microSD with the stock NixOS aarch64
# SD image: U-Boot reading extlinux entries, mainline kernel from
# cache.nixos.org. hosts/pi5/hardware.nix is the Pi 5's (nixos-raspberrypi), so
# a Pi 3 host takes this one with `platform = "raspberry-pi-3"` in its deploy
# entry.
#
# Importing the SD image module gives the filesystems the image is flashed
# with (NIXOS_SD as /, FIRMWARE as /boot/firmware), the extlinux bootloader and
# the grow-on-first-boot of the root partition, so a card flashed from the
# official image switches to this configuration in place, the way the Pi 5 does
# (docs/pi3-satellite.md).
#
# 1 GB of RAM: compressed swap in RAM keeps a build or a nix evaluation from
# being killed, and the journal stays in memory so the card isn't written to
# for every log line.
{
  lib,
  modulesPath,
  ...
}:

{
  imports = [ (modulesPath + "/installer/sd-card/sd-image-aarch64.nix") ];

  nixpkgs.hostPlatform = "aarch64-linux";

  # Wi-Fi/Bluetooth firmware (brcmfmac43430/43455, BCM43430A1.hcd) and the VideoCore blobs.
  hardware.enableRedistributableFirmware = true;

  # The on-board Ethernet is a USB device (smsc95xx on the 3 B, lan78xx on the
  # 3 B+), so udev would name it after its MAC address. A fixed name lets the
  # deploy entry say `interface = "eth0"` before the Pi has ever booted.
  systemd.network.links."10-lan" = {
    matchConfig.Driver = "smsc95xx lan78xx";
    linkConfig.Name = "eth0";
  };

  zramSwap = {
    enable = true;
    memoryPercent = 100;
  };

  services.journald.extraConfig = ''
    Storage=volatile
    RuntimeMaxUse=32M
  '';

  # The image's console loglevel of 7 floods the serial line and the journal.
  boot.consoleLogLevel = lib.mkForce 4;
}
