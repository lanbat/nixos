# tests/fixtures/multi-profile-deploy.nix
#
# Minimal multi-profile deploy manifest for load-deployments checks.
{ inputs, ... }:
{
  profiles = {
    homelab = {
      deployment = {
        domain = "home.test";
        rootDomain = "test";
        # provider "none" so the fixture needs no encrypted files.
        secrets = {
          provider = "none";
          root = ../../secrets;
        };
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
        adminSshKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExampleExample homelab";
        haLlm = {
          baseUrl = "https://llm.test/v1";
          model = "test-model";
        };
        voiceRooms = { };
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
            system = "/dev/disk/by-id/homelab-system-disk";
          };
          plugins = [
            inputs.self.lanbatPlugins.services
          ];
          # The fixture has no cameras; Frigate refuses that unless told.
          modules = [ { lanbat.services.frigate.settings.allowNoCameras = true; } ];
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
              a = "homelab-storage-a";
              b = "homelab-storage-b";
            };
          };
          plugins = [
            inputs.self.lanbatPlugins.tv
          ];
        };
      };
    };

    cabin = {
      deployment = {
        domain = "cabin.test";
        rootDomain = "test";
        # provider "none" so the fixture needs no encrypted files.
        secrets = {
          provider = "none";
          root = ../../secrets;
        };
        gatewayIp = "192.0.2.1";
        lanSubnet = "192.0.2.0/24";
        nfsIdmapdDomain = "cabin.test";
        timezone = "UTC";
        phoneRegion = "GB";
        haLatitude = "52.0";
        haLongitude = "-1.0";
        haElevation = 100;
        zigbeeVendorId = "10c4";
        zigbeeProductId = "ea60";
        adminSshKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExampleExample cabin";
        haLlm = {
          baseUrl = "https://llm.cabin.test/v1";
          model = "test-model";
        };
        voiceRooms = { };
      };

      hosts = {
        server = {
          role = "server";
          system = "x86_64-linux";
          networking = {
            ip = "192.0.2.20";
            interface = "eno1";
            hostname = "server";
          };
          disks = {
            system = "/dev/disk/by-id/cabin-system-disk";
          };
          plugins = [
            inputs.self.lanbatPlugins.services
          ];
          # The fixture has no cameras; Frigate refuses that unless told.
          modules = [ { lanbat.services.frigate.settings.allowNoCameras = true; } ];
        };
      };
    };
  };
}
