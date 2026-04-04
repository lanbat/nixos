# modules/common/settings.nix
#
# Top-level homelab configuration options.
# Import this in every host config to make the options available.
#
# All deployment-specific values live here and are set via local.nix
# (gitignored). See local.nix.example for the template.
{ lib, ... }:

{
  options.lanbat = {

    # -------------------------------------------------------------------------
    # Network identity
    # -------------------------------------------------------------------------
    domain = lib.mkOption {
      type        = lib.types.str;
      default     = "home.example.com";
      description = ''
        Base service subdomain. All services are exposed as <name>.<domain>.
        DNS for *.<domain> must point to the server.
      '';
    };

    rootDomain = lib.mkOption {
      type        = lib.types.str;
      default     = "example.com";
      description = "Root DNS zone. Typically the parent of lanbat.domain.";
    };

    serverIp = lib.mkOption {
      type        = lib.types.str;
      default     = "CHANGE_ME_SERVER_IPV4";
      example     = "192.168.1.10";
      description = "Static IPv4 address of the main server.";
    };

    piIp = lib.mkOption {
      type        = lib.types.str;
      default     = "CHANGE_ME_PI_IPV4";
      example     = "192.168.1.11";
      description = "Static IPv4 address of the Raspberry Pi.";
    };

    gatewayIp = lib.mkOption {
      type        = lib.types.str;
      default     = "CHANGE_ME_GATEWAY_IPV4";
      example     = "192.168.1.1";
      description = "Default gateway IPv4 address (usually your router).";
    };

    lanSubnet = lib.mkOption {
      type        = lib.types.str;
      default     = "192.168.0.0/16";
      example     = "192.168.1.0/24";
      description = ''
        LAN subnet in CIDR notation. Used to restrict LAN-only services
        (e.g. Mosquitto MQTT) from the internet.
      '';
    };

    serverHostname = lib.mkOption {
      type        = lib.types.str;
      default     = "server";
      description = "Hostname of the main server.";
    };

    piHostname = lib.mkOption {
      type        = lib.types.str;
      default     = "pi5";
      description = ''
        Hostname of the Raspberry Pi. Used as the NFS server address.
        Can be set to piIp instead if hostname resolution is unreliable.
      '';
    };

    nfsIdmapdDomain = lib.mkOption {
      type        = lib.types.str;
      default     = "CHANGE_ME_NFS_DOMAIN";
      example     = "home.lan";
      description = ''
        NFSv4 ID mapping domain. Must be identical on both the server and Pi.
        Can be any string — it does not need to match your DNS domain.
        A common choice is your local DNS suffix (e.g. "home.lan").
      '';
    };

    # -------------------------------------------------------------------------
    # System
    # -------------------------------------------------------------------------
    timezone = lib.mkOption {
      type        = lib.types.str;
      default     = "UTC";
      example     = "Europe/London";
      description = "System timezone, applied to both server and Pi.";
    };

    # -------------------------------------------------------------------------
    # Home Assistant location
    # -------------------------------------------------------------------------
    haLatitude = lib.mkOption {
      type        = lib.types.str;
      default     = "CHANGE_ME";
      example     = "51.5";
      description = "Home Assistant home latitude (decimal degrees).";
    };

    haLongitude = lib.mkOption {
      type        = lib.types.str;
      default     = "CHANGE_ME";
      example     = "-0.1";
      description = "Home Assistant home longitude (decimal degrees).";
    };

    haElevation = lib.mkOption {
      type        = lib.types.int;
      default     = 0;
      example     = 50;
      description = "Home Assistant home elevation above sea level (metres).";
    };

    # -------------------------------------------------------------------------
    # Locale
    # -------------------------------------------------------------------------
    phoneRegion = lib.mkOption {
      type        = lib.types.str;
      default     = "CHANGE_ME";
      example     = "GB";
      description = ''
        ISO 3166-1 alpha-2 country code for phone number formatting.
        Used by Nextcloud. Examples: GB, US, DE, FR.
      '';
    };

    # -------------------------------------------------------------------------
    # Zigbee dongle (Home Assistant / ZHA)
    # Find these with: lsusb  (vendor:product)  and  ls /dev/serial/by-id/
    # -------------------------------------------------------------------------
    zigbeeDongle = lib.mkOption {
      type        = lib.types.str;
      default     = "CHANGE_ME_ZIGBEE_DONGLE";
      example     = "usb-Silicon_Labs_Sonoff_Zigbee_3.0_USB_Dongle_Plus_0001-if00-port0";
      description = ''
        Filename under /dev/serial/by-id/ for the Zigbee USB dongle.
        Run: ls /dev/serial/by-id/
      '';
    };

    zigbeeVendorId = lib.mkOption {
      type        = lib.types.str;
      default     = "CHANGE_ME_VENDOR";
      example     = "10c4";
      description = "USB vendor ID for the Zigbee dongle (from lsusb, 4 hex digits).";
    };

    zigbeeProductId = lib.mkOption {
      type        = lib.types.str;
      default     = "CHANGE_ME_PRODUCT";
      example     = "ea60";
      description = "USB product ID for the Zigbee dongle (from lsusb, 4 hex digits).";
    };

    # -------------------------------------------------------------------------
    # Server disk — three-layer design
    # -------------------------------------------------------------------------
    # The server uses two manually-unlocked LUKS volumes that stay locked at boot.
    # Host root (sda2) is plain ext4 — no passphrase required at boot.
    # See modules/server/secure-layers.nix for the full design.

    serverControlLuksUuid = lib.mkOption {
      type        = lib.types.str;
      default     = "CHANGE_ME_CONTROL_LUKS_UUID";
      description = ''
        UUID of the server's control LUKS partition (sda3).
        Contains Tang keys. Stays locked at boot; unlocked manually.
        Find with: blkid /dev/sda3
      '';
    };

    serverWorkloadLuksUuid = lib.mkOption {
      type        = lib.types.str;
      default     = "CHANGE_ME_WORKLOAD_LUKS_UUID";
      description = ''
        UUID of the server's workload LUKS partition (sda4).
        Contains all container data, databases, service state.
        Stays locked at boot; unlocked manually.
        Find with: blkid /dev/sda4
      '';
    };

    # -------------------------------------------------------------------------
    # Raspberry Pi encrypted storage drives
    # -------------------------------------------------------------------------
    # Both NVMe drives are bound to the server's Tang service via Clevis.
    # Find stable by-id paths with:
    #   ls -la /dev/disk/by-id/ | grep nvme | grep -v part

    piStorageDriveA = lib.mkOption {
      type        = lib.types.str;
      default     = "CHANGE_ME_PI_DRIVE_A";
      example     = "nvme-Samsung_SSD_970_EVO_1TB_ABC123";
      description = ''
        Stable /dev/disk/by-id/ filename for the Pi's NVMe storage drive A.
        Do not include the /dev/disk/by-id/ prefix — just the filename.
      '';
    };

    piStorageDriveB = lib.mkOption {
      type        = lib.types.str;
      default     = "CHANGE_ME_PI_DRIVE_B";
      example     = "nvme-Samsung_SSD_970_EVO_1TB_XYZ456";
      description = ''
        Stable /dev/disk/by-id/ filename for the Pi's NVMe storage drive B.
        Do not include the /dev/disk/by-id/ prefix — just the filename.
      '';
    };

    # -------------------------------------------------------------------------
    # Access
    # -------------------------------------------------------------------------
    adminSshKey = lib.mkOption {
      type        = lib.types.str;
      default     = "CHANGE_ME_ADMIN_SSH_PUBKEY";
      description = ''
        SSH public key for the admin user on both machines.
        Generate with: ssh-keygen -t ed25519
        Get the value with: cat ~/.ssh/id_ed25519.pub
      '';
    };

  };
}
