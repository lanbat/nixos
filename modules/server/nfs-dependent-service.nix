# modules/server/nfs-dependent-service.nix
#
# NixOS module option that makes it easy to declare a service as
# "depends on Pi NFS storage".
#
# Usage in a service module:
#
#   imports = [ ../../modules/server/nfs-dependent-service.nix ];
#   lanbat.nfsDependsOn = [ "a" ];   # or [ "a" "b" ] for both drives
#
# What this does
# --------------
# For each declared drive, it appends to the named systemd service:
#   After    = srv-storage-<drive>.mount
#   BindsTo  = srv-storage-<drive>.mount   ← stops service when mount dies
#   RequiresMountsFor = /srv/storage/<drive>
#
# The service must be passed in via the `lanbat.nfsDependsOn.service` option
# or the module can be imported directly by the service nix file and the
# service name resolved internally.
#
# In practice every service module that depends on NFS imports this module
# and calls the helper directly — see hosts/server/services/*.nix.
{ config, lib, ... }:

with lib;

let
  mountUnitName = drive: "srv-storage-${drive}.mount";
  mountPath     = drive: "/srv/storage/${drive}";
in
{
  options.lanbat = {
    # Each service module may register itself here.
    nfsDependentServices = mkOption {
      type = types.attrsOf (types.listOf (types.enum [ "a" "b" ]));
      default = {};
      description = ''
        Map of systemd service name → list of NFS drives it depends on.
        Example: { "podman-jellyfin" = [ "a" ]; }
      '';
    };
  };

  config = {
    # For each registered service, wire up the systemd dependencies.
    systemd.services = lib.mapAttrs' (svcName: drives:
      lib.nameValuePair svcName {
        after   = map mountUnitName drives;
        bindsTo = map mountUnitName drives;
        # after + bindsTo already express the dependency; RequiresMountsFor
        # is redundant and conflicts with values set by NixOS service modules.
        # Restart on failure so the service comes back when the mount is restored.
        serviceConfig.Restart = lib.mkDefault "on-failure";
        serviceConfig.RestartSec = lib.mkDefault "10s";
      }
    ) config.lanbat.nfsDependentServices;
  };
}
