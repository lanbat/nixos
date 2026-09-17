# tests/lib/mk-host-fixture.nix
#
# Minimal deploy manifest and mkHost-built systems for VM tests.
{
  pkgs,
  agenix,
  inputs,
  nixpkgs,
  nixos-raspberrypi,
  disko,
}:

let
  lib = nixpkgs.lib;

  lanbatPlugins = {
    services = import ../../plugins/services;
    tv = import ../../plugins/tv;
    voice = import ../../plugins/voice;
  };

  inputsWithSelf = inputs // {
    self = (inputs.self or { }) // {
      inherit lanbatPlugins;
    };
  };

  mkHost = import ../../lib/mkHost.nix;

  profileName = "test";

  deploy = {
    deployment = {
      domain = "home.test";
      rootDomain = "test";
      gatewayIp = "192.0.2.1";
      lanSubnet = "192.0.2.0/24";
      nfsIdmapdDomain = "home.test";
      timezone = "UTC";
      phoneRegion = "GB";
      haLatitude = "51.5";
      haLongitude = "-0.1";
      haElevation = 0;
      zigbeeVendorId = "10c4";
      zigbeeProductId = "ea60";
      adminSshKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExampleExample test";
      haLlm = {
        baseUrl = "https://llm.test/v1";
        model = "test-model";
      };
      voiceRooms = {
        "Living Room" = "pi-storage";
      };
    };

    hosts = {
      server = {
        role = "server";
        system = "x86_64-linux";
        networking = {
          ip = "192.0.2.10";
          interface = "eno1";
          hostname = "server";
        };
        disks = {
          system = "/dev/disk/by-id/test-system-disk";
        };
        plugins = [
          inputsWithSelf.self.lanbatPlugins.services
        ];
      };

      pi-storage = {
        role = "storage-pi";
        system = "aarch64-linux";
        platform = "raspberry-pi";
        networking = {
          ip = "192.168.1.2";
          interface = "eth1";
          hostname = "pi5";
        };
        storage = {
          drives = {
            a = "test-storage-a";
            b = "test-storage-b";
          };
        };
        plugins = [
          inputsWithSelf.self.lanbatPlugins.voice
        ];
      };

      voice-pi = {
        role = "voice-pi";
        system = "aarch64-linux";
        platform = "raspberry-pi";
        networking = {
          ip = "192.0.2.12";
          interface = "eth1";
          hostname = "voice-pi";
        };
        plugins = [
          inputsWithSelf.self.lanbatPlugins.voice
        ];
      };
    };
  };

  mkHostFor =
    hostName: hostCfg:
    mkHost {
      inherit
        lib
        inputs
        agenix
        disko
        nixos-raspberrypi
        profileName
        hostName
        hostCfg
        ;
      deployment = deploy.deployment;
      hosts = deploy.hosts;
    };

  piStorageSystem = mkHostFor "pi-storage" deploy.hosts.pi-storage;
  voicePiSystem = mkHostFor "voice-pi" deploy.hosts.voice-pi;

  hardwareModule = ../../hosts/pi/hardware.nix;

  # VM tests use virtio disks, not Pi SD labels; skip hardware.nix (needs nixos-raspberrypi).
  piStorageTestModules = lib.filter (m: m != hardwareModule) piStorageSystem.lanbatModules;
  voicePiTestModules = lib.filter (m: m != hardwareModule) voicePiSystem.lanbatModules;

  vmTestModules = [
    ./test-secrets.nix
    (
      { lib, ... }:
      {
        nixpkgs.hostPlatform = lib.mkForce "aarch64-linux";

        virtualisation.memorySize = 2048;

        services.timesyncd.enable = lib.mkForce false;

        lanbat.testSecrets.telegraf-token = "TELEGRAF_INFLUXDB_TOKEN=test-influx-token\n";
        lanbat.testSecrets.ha-voice-token = "test-voice-token";

        # OSTest provides a virtio root disk; Pi SD labels from hardware.nix are absent.
        fileSystems."/" = lib.mkForce {
          device = "/dev/vda";
          fsType = "ext4";
        };
        fileSystems."/boot/firmware".device = lib.mkForce "/dev/vda";
        boot.loader.grub.enable = lib.mkForce true;
      }
    )
  ];

  # Module for runNixOSTest nodes (expects a module, not a nixosSystem).
  piStorageConfig =
    { ... }:
    {
      imports = piStorageTestModules ++ vmTestModules;
    };

  voicePiConfig =
    { ... }:
    {
      imports = voicePiTestModules ++ vmTestModules;
    };

  mkPiStorageHost = args: (import ./mk-host-fixture.nix args).piStorageConfig;
in
{
  inherit
    deploy
    profileName
    mkHostFor
    mkPiStorageHost
    piStorageSystem
    voicePiSystem
    piStorageConfig
    voicePiConfig
    ;
}
