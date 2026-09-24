# deployments/example/deploy.nix
#
# Example deployment profile for CI and contributors.
{ inputs, ... }:
{
  deployment = {
    domain = "home.example.com";
    rootDomain = "example.com";
    gatewayIp = "192.0.2.1";
    lanSubnet = "192.0.2.0/24";
    nfsIdmapdDomain = "home.lan";
    timezone = "UTC";
    phoneRegion = "GB";
    haLatitude = "51.5";
    haLongitude = "-0.1";
    haElevation = 0;
    zigbeeVendorId = "10c4";
    zigbeeProductId = "ea60";
    adminSshKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExampleExample example";
    # How hosts reach each other. "none" keeps cross-host traffic on the LAN,
    # which is also what leaving this out means. For a WireGuard mesh, set
    # provider = "wireguard-mesh" with subnet and domain, and give each host
    # an overlay block (commented out below); see docs/extensibility.md.
    overlay = {
      provider = "none";
      # subnet = "10.100.0.0/24";
      # domain = "lanbat.internal";
    };
    # The example profile is read and evaluated, never deployed, so it resolves
    # secrets to placeholders. That is what lets somebody add a service with
    # secrets and run nix flake check without holding any keys or committing an
    # empty .age file to make evaluation pass.
    secrets = {
      provider = "none";
      root = ../../secrets;
    };
    haLlm = {
      baseUrl = "https://llm.example.com/v1";
      model = "example-model";
    };
    voiceRooms = {
      "Office" = "server";
      "Living Room" = "pi-storage";
    };
    # Xiaomi BLE bind keys for Home Assistant, from ha-xiaomi-ble.age.
    haXiaomiBle = true;
    # Xiaomi BLE thermometers with a clock display, for lanbatPlugins.xiaomi-clock.
    xiaomiClocks = [ "A4:C1:38:00:00:01" ];

    # Android TV boxes, for lanbatPlugins.android.
    androidDevices = {
      bedroom = {
        host = "192.0.2.50";
        packages = [ "de.badaix.snapcast" ];
      };
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
      # overlay = {
      #   ip = "10.100.0.1";
      #   publicKey = "<from nix run .#overlay-keys>";
      #   endpoint = "192.0.2.10:51820"; # can be dialled
      # };
      disks = {
        system = "/dev/disk/by-id/example-system-disk";
      };
      plugins = [
        inputs.self.lanbatPlugins.services
        inputs.self.lanbatPlugins.android
        inputs.self.lanbatPlugins.xiaomi-clock
      ];
    };

    pi-storage = {
      role = "storage-pi";
      system = "aarch64-linux";
      platform = "raspberry-pi";
      networking = {
        ip = "192.0.2.11";
        interface = "end0";
        hostname = "pi5";
      };
      # overlay = {
      #   ip = "10.100.0.2";
      #   publicKey = "<from nix run .#overlay-keys>";
      #   # No endpoint: dials out to the server.
      # };
      storage = {
        drives = {
          a = "example-storage-a";
          b = "example-storage-b";
        };
      };
      plugins = [
        inputs.self.lanbatPlugins.tv
        inputs.self.lanbatPlugins.voice
      ];
    };
  };
}
