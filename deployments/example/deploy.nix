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
    haLlm = {
      baseUrl = "https://llm.example.com/v1";
      model = "example-model";
    };
    voiceRooms = {
      "Office" = "server";
      "Living Room" = "pi-storage";
    };

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
      disks = {
        system = "/dev/disk/by-id/example-system-disk";
      };
      plugins = [
        inputs.self.lanbatPlugins.services
        inputs.self.lanbatPlugins.android
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
