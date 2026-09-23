# modules/server/xiaomi-clock.nix
#
# Keeps the clock right on Xiaomi BLE thermometers that have a display
# (LYWSD02/LYWSD02MMC).  Enabled through the lanbat-xiaomi-clock plugin.
#
# Why this exists
# ---------------
# These devices have no time source of their own: no NTP, no radio signal, no
# RTC sync.  The Mi Home app wrote the time over GATT each time it was opened,
# which is the only reason a stock one is ever right.  Running the device
# locally means it is not bound to Mi Home, so nothing writes it, and they ship
# from the factory on UTC+8.
#
# Home Assistant cannot do this either: its xiaomi_ble integration is strictly
# passive.  It parses broadcast advertisements and never opens a GATT
# connection, so it can read the temperature but can never set the clock.
#
# What it does
# ------------
# xiaomi-clock-sync connects to each address in lanbat.deployment.xiaomiClocks
# and writes the UTC epoch plus the current UTC offset.  The offset is taken
# from the system timezone on every run, so a daylight saving change corrects
# itself on the next tick -- the job Mi Home used to do.
#
# Timing
# ------
# The thermometers are sleepy: they advertise every few seconds and a
# connection can only be opened during an advertising window, so a run can take
# minutes and can fail outright when the device is asleep or out of range.  The
# unit therefore tolerates failure rather than reporting it: a missed run is
# normal and the next tick picks it up.  Daily is ample -- the crystal drifts
# only seconds a day, and the real work is the twice-yearly DST correction.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  clocks = config.lanbat.deployment.xiaomiClocks;
  syncTool = pkgs.callPackage ../../pkgs/xiaomi-clock-sync { };
in
{
  config = lib.mkIf (clocks != [ ]) {
    # The plugin has to stand on its own: the server may run this without the
    # services plugin, which is what otherwise brings BlueZ in.  mkDefault so
    # services/home-assistant.nix can still turn it on unconditionally.
    hardware.bluetooth.enable = lib.mkDefault true;

    systemd.services.xiaomi-clock-sync = {
      description = "Set the clock on Xiaomi BLE thermometers";

      # BlueZ publishes the adapter on D-Bus; without it there is nothing to
      # connect through.  Wanted, not required: a failed adapter must not make
      # this unit fail noisily on a schedule.
      after = [ "bluetooth.service" ];
      wants = [ "bluetooth.service" ];

      serviceConfig = {
        Type = "oneshot";
        User = "root";
        # A single run waits through several advertising windows per device.
        TimeoutStartSec = "30min";
      };

      environment.XIAOMI_CLOCK_DEVICES = lib.concatStringsSep " " clocks;

      script = "exec ${lib.getExe syncTool}";
    };

    systemd.timers.xiaomi-clock-sync = {
      description = "Set the clock on Xiaomi BLE thermometers daily";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # Soon after boot so a power cycle is corrected without waiting a day,
        # then once a day. Persistent catches up a run missed while powered off.
        OnBootSec = "10min";
        OnCalendar = "daily";
        Persistent = true;
        RandomizedDelaySec = "30min";
      };
    };
  };
}
