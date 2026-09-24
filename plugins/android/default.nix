# plugins/android/default.nix
#
# Declarative provisioning for Android TV boxes over ADB.  Set
# lanbat.deployment.androidDevices to the boxes -- with none listed the plugin
# configures nothing.
{
  name = "lanbat-android";
  version = 2;
  roles = [ "server" ];
  modules = [
    ../../modules/server/android-devices.nix
    (
      { config, ... }:
      {
        androidDevices = config.lanbat.deployment.androidDevices;
      }
    )
  ];
}
