# services/mosquitto.nix
#
# Mosquitto MQTT broker.
#
# Used by:
#   - Frigate → publishes detection events
#   - Home Assistant → subscribes to Frigate events, publishes automations
#   - Any future IoT devices on the LAN
#
# Auth model
# ----------
# Mosquitto uses a local password file.  Passwords are set via
# `mosquitto_passwd`.  This is simple, reliable, and sufficient for
# a trusted LAN.
#
# Listener binds to 0.0.0.0 (LAN-facing) so IoT devices can connect.
# The firewall restricts access to the LAN subnet only.
#
# Always-on: yes.  No NFS dependency.
{
  config,
  pkgs,
  lib,
  ...
}:

{
  lanbat.services.mosquitto = {
    endpoint = {
      scheme = "mqtt";
      port = 1883;
    };
    extraPorts = [ 1883 ];
    # Plaintext passwords, one line each. Frigate reads its password too.
    secrets = {
      # homeassistant-bootstrap reads this to configure the MQTT integration.
      mosquitto-ha-pass = {
        group = "hass";
        mode = "0440";
      };
      mosquitto-frigate-pass = { };
      mosquitto-z2m-pass = { };
    };
  };

  services.mosquitto = {
    enable = true;

    listeners = [
      {
        port = 1883;
        address = "0.0.0.0";

        settings = {
          allow_anonymous = false;
        };

        acl = [
          # Allow all authenticated users to publish/subscribe everywhere.
          # Tighten this if you add untrusted IoT devices.
          "topic readwrite #"
        ];

        users = {
          # Home Assistant user.
          # agenix secret file must contain the plaintext password (one line).
          homeassistant = {
            passwordFile = config.age.secrets.mosquitto-ha-pass.path;
            acl = [ "readwrite #" ];
          };

          # Frigate user.
          frigate = {
            passwordFile = config.age.secrets.mosquitto-frigate-pass.path;
            acl = [
              "readwrite frigate/#"
              "readwrite homeassistant/#"
            ];
          };

          # Zigbee2MQTT user.
          zigbee2mqtt = {
            passwordFile = config.age.secrets.mosquitto-z2m-pass.path;
            acl = [
              "readwrite zigbee2mqtt/#"
              "readwrite homeassistant/#"
            ];
          };
        }
        // lib.mapAttrs (name: user: {
          passwordFile = user.passwordFile;
          acl = user.acl;
        }) config.lanbat.mosquitto.extraUsers;
      }
    ];
  };

  # Reachability is generated from the declared edges by
  # modules/wiring/policy.nix: every service that consumes mosquitto is admitted
  # and nothing else is. The rules this file used to write admitted the whole
  # LAN subnet, which nothing used — 301 client connections over fourteen days
  # were all from 127.0.0.1, which the generated drop exempts.
}
