# modules/core/settings.nix
#
# Deployment-specific settings. None of them have defaults: every host
# configuration must set them, so a missing value fails evaluation instead of
# deploying a placeholder.
#
# Real values live in local.nix (gitignored, see local.nix.example), which
# flake.nix only loads for the `server` and `pi` configurations. CI and
# contributors evaluate `example-server` and `example-pi`, which take their
# values from hosts/example-settings.nix.
{ lib, ... }:

let
  inherit (lib) mkOption types;

  ipv4 = types.strMatching "([0-9]{1,3}\\.){3}[0-9]{1,3}";
in
{
  options.lanbat = {

    # ── Network identity ──────────────────────────────────────────────────────
    domain = mkOption {
      type = types.str;
      example = "home.example.com";
      description = ''
        Base service domain. Services are exposed as <name>.<domain>.
        DNS for *.<domain> must point to the server.
      '';
    };

    rootDomain = mkOption {
      type = types.str;
      example = "example.com";
      description = "Root DNS zone, typically the parent of lanbat.domain. Camera hostnames live here.";
    };

    serverIp = mkOption {
      type = ipv4;
      example = "192.168.1.10";
      description = "Static IPv4 address of the server. Also the deploy-rs target.";
    };

    piIp = mkOption {
      type = ipv4;
      example = "192.168.1.11";
      description = "Static IPv4 address of the Raspberry Pi. Also the deploy-rs target.";
    };

    gatewayIp = mkOption {
      type = ipv4;
      example = "192.168.1.1";
      description = "Default gateway (usually the router).";
    };

    lanSubnet = mkOption {
      type = types.strMatching "([0-9]{1,3}\\.){3}[0-9]{1,3}/[0-9]{1,2}";
      example = "192.168.1.0/24";
      description = "LAN subnet in CIDR notation. LAN-only services (e.g. MQTT) are restricted to it.";
    };

    serverHostname = mkOption {
      type = types.str;
      example = "server";
      description = "Hostname of the server.";
    };

    serverInterface = mkOption {
      type = types.str;
      example = "enp1s0";
      description = "Network interface of the server that gets serverIp. Find it with: ip -o link";
    };

    piHostname = mkOption {
      type = types.str;
      example = "pi5";
      description = "Hostname of the Raspberry Pi. The server mounts NFS from it.";
    };

    nfsIdmapdDomain = mkOption {
      type = types.str;
      example = "home.lan";
      description = "NFSv4 ID mapping domain, identical on both hosts. Any string works.";
    };

    # ── System ────────────────────────────────────────────────────────────────
    timezone = mkOption {
      type = types.str;
      example = "Europe/London";
      description = "System timezone of both hosts.";
    };

    phoneRegion = mkOption {
      type = types.strMatching "[A-Z]{2}";
      example = "GB";
      description = "ISO 3166-1 alpha-2 country code for phone number formatting (Nextcloud).";
    };

    # ── Home Assistant location ───────────────────────────────────────────────
    haLatitude = mkOption {
      type = types.str;
      example = "51.5";
      description = "Home latitude in decimal degrees.";
    };

    haLongitude = mkOption {
      type = types.str;
      example = "-0.1";
      description = "Home longitude in decimal degrees.";
    };

    haElevation = mkOption {
      type = types.int;
      example = 50;
      description = "Home elevation above sea level in metres.";
    };

    # ── Zigbee dongle (find with lsusb) ───────────────────────────────────────
    zigbeeVendorId = mkOption {
      type = types.strMatching "[0-9a-f]{4}";
      example = "10c4";
      description = "USB vendor ID of the Zigbee dongle.";
    };

    zigbeeProductId = mkOption {
      type = types.strMatching "[0-9a-f]{4}";
      example = "ea60";
      description = "USB product ID of the Zigbee dongle.";
    };

    # ── Disks ─────────────────────────────────────────────────────────────────
    serverDisk = mkOption {
      type = types.strMatching "/dev/disk/by-id/.+";
      example = "/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_2TB_S7KHNJ0W123456";
      description = ''
        The server's system disk. hosts/server/disk.nix partitions it during
        installation, erasing it. Find it from the installer with
        ls -l /dev/disk/by-id/
      '';
    };

    piStorageDriveA = mkOption {
      type = types.str;
      example = "nvme-Samsung_SSD_970_EVO_1TB_ABC123";
      description = "/dev/disk/by-id/ filename (without the prefix) of the Pi's storage drive A.";
    };

    piStorageDriveB = mkOption {
      type = types.str;
      example = "nvme-Samsung_SSD_970_EVO_1TB_XYZ456";
      description = "/dev/disk/by-id/ filename (without the prefix) of the Pi's storage drive B.";
    };

    # ── Access ────────────────────────────────────────────────────────────────
    adminSshKey = mkOption {
      type = types.strMatching "(ssh-|ecdsa-|sk-).+";
      example = "ssh-ed25519 AAAAC3Nza... admin@workstation";
      description = "SSH public key of the admin user on both hosts. deploy-rs connects with it.";
    };
  };
}
