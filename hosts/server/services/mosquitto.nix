# hosts/server/services/mosquitto.nix
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
{ config, pkgs, lib, ... }:

{
  services.mosquitto = {
    enable = true;

    listeners = [
      {
        port    = 1883;
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
            acl = [ "readwrite frigate/#" "readwrite homeassistant/#" ];
          };

          # Zigbee2MQTT user.
          zigbee2mqtt = {
            passwordFile = config.age.secrets.mosquitto-z2m-pass.path;
            acl = [ "readwrite zigbee2mqtt/#" "readwrite homeassistant/#" ];
          };
        };
      }
    ];
  };

  # Allow LAN devices and localhost to reach MQTT.
  # Localhost must be explicitly allowed — HA and Z2M connect from 127.0.0.1.
  #
  # Rule order: insert DROP first so it ends up at the bottom after the two
  # ACCEPT rules (each -I pushes earlier insertions down).
  # extraStopCommands removes the rules on reload to prevent accumulation.
  networking.firewall.extraCommands = ''
    iptables -I INPUT -p tcp --dport 1883 ! -s ${config.lanbat.lanSubnet} -j DROP
    iptables -I INPUT -p tcp --dport 1883 -s ${config.lanbat.lanSubnet} -j ACCEPT
    iptables -I INPUT -p tcp --dport 1883 -s 127.0.0.1 -j ACCEPT
  '';
  networking.firewall.extraStopCommands = ''
    iptables -D INPUT -p tcp --dport 1883 -s 127.0.0.1 -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -p tcp --dport 1883 -s ${config.lanbat.lanSubnet} -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -p tcp --dport 1883 ! -s ${config.lanbat.lanSubnet} -j DROP 2>/dev/null || true
  '';
}
