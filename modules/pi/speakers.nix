# modules/pi/speakers.nix
#
# Which speaker a Pi plays through: the analog jack, a USB sound card or
# speaker, or a Bluetooth speaker.
#
# Snapcast's client, the voice satellite's replies and everything else play to
# the system-wide PipeWire's default output (modules/pi/audio.nix), so choosing
# a speaker is choosing that default. All three kinds are always available;
# WirePlumber picks the default among the outputs it has, and `output` raises
# the chosen kind above the others, so a speaker that is switched off or
# unplugged lets the next one take over.
#
#   lanbat.speakers.output = "auto";        # WirePlumber's own choice
#   lanbat.speakers.output = "analog";      # the 3.5 mm jack (Pi 3/4)
#   lanbat.speakers.output = "usb";         # a USB sound card or speaker
#   lanbat.speakers.output = "bluetooth";   # a paired Bluetooth speaker
#
# Bluetooth
# ---------
# The speaker has to be paired once, by hand; BlueZ remembers it after that
# (docs/pi3-satellite.md):
#
#   bluetoothctl
#   > scan on
#   > pair AA:BB:CC:DD:EE:FF
#   > trust AA:BB:CC:DD:EE:FF
#   > connect AA:BB:CC:DD:EE:FF
#
# Most speakers do not reconnect to the Pi by themselves after being switched
# off and on, so with `bluetooth.address` set a service asks BlueZ to connect
# every half minute while it is not connected.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkOption types;
  cfg = config.lanbat.speakers;

  # Output nodes by their PipeWire name. The analog jack of the Pi 3/4 is
  # alsa_output.platform-bcm2835_audio.*, a USB device alsa_output.usb-*.
  pattern = {
    analog = "~alsa_output.platform-bcm2835_audio.*";
    usb = "~alsa_output.usb-.*";
    bluetooth = "~bluez_output.*";
  };

  # WirePlumber's default priority is around 1000 for ALSA nodes, so this
  # clears them.
  preferred = 3000;

  bluetoothctl = "${config.hardware.bluetooth.package}/bin/bluetoothctl";
in
{
  options.lanbat.speakers = {
    output = mkOption {
      type = types.enum [
        "auto"
        "analog"
        "usb"
        "bluetooth"
      ];
      default = "auto";
      description = "The kind of speaker that plays by default when it is available.";
    };

    bluetooth.address = mkOption {
      type = types.nullOr (types.strMatching "([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}");
      default = null;
      example = "AA:BB:CC:DD:EE:FF";
      description = ''
        Address of the paired Bluetooth speaker. Set, it is reconnected
        whenever it is not connected, for example after it has been switched
        off and on.
      '';
    };
  };

  config = {
    hardware.bluetooth = {
      enable = true;
      powerOnBoot = true;
    };

    services.pipewire.wireplumber.extraConfig = lib.mkIf (cfg.output != "auto") {
      "52-preferred-speaker" = {
        "monitor.alsa.rules" = lib.optionals (cfg.output != "bluetooth") [
          {
            matches = [ { "node.name" = pattern.${cfg.output}; } ];
            actions.update-props."priority.session" = preferred;
          }
        ];
        "monitor.bluez.rules" = lib.optionals (cfg.output == "bluetooth") [
          {
            matches = [ { "node.name" = pattern.bluetooth; } ];
            actions.update-props."priority.session" = preferred;
          }
        ];
      };
    };

    systemd.services.speaker-bluetooth-connect = lib.mkIf (cfg.bluetooth.address != null) {
      description = "Reconnect the Bluetooth speaker";
      after = [ "bluetooth.service" ];
      wants = [ "bluetooth.service" ];
      serviceConfig.Type = "oneshot";
      script = ''
        if ! ${bluetoothctl} info ${cfg.bluetooth.address} | ${pkgs.gnugrep}/bin/grep -q 'Connected: yes'; then
          ${bluetoothctl} connect ${cfg.bluetooth.address} || true
        fi
      '';
    };
    systemd.timers.speaker-bluetooth-connect = lib.mkIf (cfg.bluetooth.address != null) {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "20s";
        OnUnitActiveSec = "30s";
      };
    };
  };
}
