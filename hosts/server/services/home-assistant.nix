# hosts/server/services/home-assistant.nix
#
# Home Assistant — home automation hub.
#
# Why the NixOS module and not a container?
#   The NixOS `services.home-assistant` module handles component packaging,
#   config dir, user/group, and service lifecycle very cleanly.
#   It is significantly easier to maintain than a container for HA specifically
#   because NixOS can manage the Python component set declaratively.
#
# USB/Zigbee dongle
# -----------------
# The Zigbee USB dongle (e.g. ConBee II, Sonoff Zigbee 3.0) appears as
# /dev/serial/by-id/... — set ZIGBEE_DEVICE_PATH below.
#
# Auth with Authentik
# -------------------
# Home Assistant does NOT have a built-in OIDC auth provider.
# The recommended approach for HA + Authentik in a homelab:
#
#   Option A (simplest): keep HA local accounts only.
#     Caddy terminates TLS; HA handles auth itself.
#     Use a strong HA admin password stored in your password manager.
#
#   Option B (better SSO): use Authentik as an OAuth2 Source in HA.
#     In HA: Settings → Users → Auth Providers is NOT where you do this.
#     Instead: install the "Authentik" or "generic_oauth" HACS integration
#     and configure it to point to Authentik's OIDC endpoint.
#     See docs/authentik-setup.md § Home Assistant.
#
# Local admin is always kept — it is the break-glass account regardless
# of which option you choose.
#
# Always-on: yes — HA should survive Pi NFS loss.
{ config, pkgs, lib, ... }:

let
  domain      = config.lanbat.domain;
  zigbeeDevice = "/dev/serial/by-id/${config.lanbat.zigbeeDongle}";
in
{
  services.home-assistant = {
    enable = true;
    package = pkgs.unstable.home-assistant;
    openFirewall = false; # Caddy handles exposure.

    # Install extra Python components declaratively.
    # Add/remove from this list; nixos-rebuild will install them.
    extraComponents = [
      "default_config"
      "met"             # weather
      "radio_browser"
      "zha"             # Zigbee Home Automation (works with most dongles)
      # "deconz"        # alternative: deCONZ / ConBee
      "mqtt"
      "mobile_app"
      "person"
      "history"
      "logbook"
      "recorder"
      "frontend"
      "config"
      "lovelace"
      "network"
      "stream"
      "camera"
      "ffmpeg"
      # Wyoming voice assistant protocol
      "wyoming"
    ];

    config = {
      # Trust Caddy as reverse proxy.
      http = {
        use_x_forwarded_for = true;
        trusted_proxies      = [ "127.0.0.1" "::1" ];
        ip_ban_enabled       = true;
        login_attempts_threshold = 5;
      };

      homeassistant = {
        name         = "Home";
        latitude     = config.lanbat.haLatitude;
        longitude    = config.lanbat.haLongitude;
        elevation    = config.lanbat.haElevation;
        unit_system  = "metric";
        time_zone    = config.lanbat.timezone;
      };

      # Recorder — keep 30 days in SQLite.
      recorder = {
        purge_keep_days = 30;
        db_url = "sqlite:////var/lib/hass/home-assistant_v2.db";
      };

      # Auth: HA local accounts are the primary method.
      # To add Authentik SSO, install the "Authentik" integration from HACS
      # (https://github.com/jchonig/ha-authentik) and configure it via the
      # HA UI.  No additional configuration.yaml entry is needed here.
      #
      # The trusted_proxies setting above (127.0.0.1) is the important part —
      # it lets HA trust the X-Forwarded-For header from Caddy so that
      # IP-based rate limiting works correctly.
    };
  };

  # Give HA access to the Zigbee USB dongle.
  services.udev.extraRules = ''
    SUBSYSTEM=="tty", ATTRS{idVendor}=="${config.lanbat.zigbeeVendorId}", \
      ATTRS{idProduct}=="${config.lanbat.zigbeeProductId}", \
      SYMLINK+="zigbee", GROUP="ha", MODE="0660"
  '';

  users.groups.ha = {};

  users.users.hass = {
    extraGroups = [ "dialout" "ha" ];
  };

  # HA state lives entirely on server-local storage — resilient to Pi loss.
  # /var/lib/hass is managed by the NixOS module.
}
