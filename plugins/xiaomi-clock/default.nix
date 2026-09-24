# plugins/xiaomi-clock/default.nix
#
# Clock sync for Xiaomi BLE thermometers with a display (LYWSD02/LYWSD02MMC).
# They have no time source of their own and ship on UTC+8; a daily timer writes
# the time over Bluetooth.  Set lanbat.deployment.xiaomiClocks to the device
# addresses -- with none listed the plugin configures nothing.
{
  name = "lanbat-xiaomi-clock";
  version = 2;
  roles = [ "server" ];
  modules = [
    ../../modules/server/xiaomi-clock.nix
  ];
}
