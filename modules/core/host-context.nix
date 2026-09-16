# modules/core/host-context.nix
#
# Computes cross-host references from lanbat.hosts after deploy injection.
{ config, lib, ... }:

let
  hostLib = import ../../lib/host.nix { inherit lib; };
  hosts = config.lanbat.hosts;
  defaultPrimaryServer = hostLib.primaryHost hosts "server";
  defaultPrimaryStorage = hostLib.primaryHost hosts "storage-pi";
in
{
  config = {
    lanbat.deployment = {
      primaryServer = lib.mkDefault defaultPrimaryServer;
      primaryStorage = lib.mkDefault defaultPrimaryStorage;
      serverIp =
        let
          primaryServer = config.lanbat.deployment.primaryServer;
        in
        if primaryServer == null then null else hostLib.hostIp hosts primaryServer;
      storageIp =
        let
          primaryStorage = config.lanbat.deployment.primaryStorage;
        in
        if primaryStorage == null then null else hostLib.hostIp hosts primaryStorage;
      storageHostname =
        let
          primaryStorage = config.lanbat.deployment.primaryStorage;
        in
        if primaryStorage == null then null else hostLib.hostHostname hosts primaryStorage;
    };

    assertions = [
      {
        assertion =
          config.lanbat.deployment.primaryServer == null
          || hosts ? ${config.lanbat.deployment.primaryServer};
        message = "lanbat.deployment.primaryServer must be a host key in lanbat.hosts";
      }
      {
        assertion =
          config.lanbat.deployment.primaryStorage == null
          || hosts ? ${config.lanbat.deployment.primaryStorage};
        message = "lanbat.deployment.primaryStorage must be a host key in lanbat.hosts";
      }
    ];
  };
}
