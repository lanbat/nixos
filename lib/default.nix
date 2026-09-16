# lib/default.nix
#
# Public lanbat library: host builder, deploy loader, and helpers.
{
  self,
  inputs,
  agenix,
  disko,
  deploy-rs,
  nixpkgs,
  nixos-raspberrypi,
  profiles,
  hasDeploy ? true,
  root ? ./.,
}:

let
  inherit (nixpkgs) lib;

  hostLib = import ./host.nix { inherit lib; };
  pluginLib = import ./plugins.nix { inherit lib; };
  validateLib = import ./validate-deploy.nix { inherit lib; };

  hostFlakeName =
    profileName: hostName:
    if profileName == "default" then hostName else "${profileName}-${hostName}";

  deployQueryLib = import ./deploy-query.nix {
    inherit lib profiles hasDeploy root hostLib hostFlakeName;
  };

  mkHost =
    profileName: deploy: hostName: hostCfg:
    import ./mkHost.nix {
      inherit
        lib
        inputs
        agenix
        disko
        nixos-raspberrypi
        profileName
        hostName
        hostCfg
        ;
      deployment = deploy.deployment;
      hosts = deploy.hosts;
    };

  mkProfile =
    profileName: deploy:
    let
      deploy' = validateLib.validateDeploy { inherit profileName; deploy = deploy; };
      hosts = lib.mapAttrs (name: cfg: mkHost profileName deploy' name cfg) deploy'.hosts;
      configurations = lib.mapAttrs' (
        name: cfg:
        lib.nameValuePair (hostFlakeName profileName name) cfg
      ) hosts;
      deployNodes = lib.mapAttrs' (
        name: hostCfg:
        let
          flakeName = hostFlakeName profileName name;
          cfg = hosts.${name}.config;
          hostIp = hostLib.hostIp cfg.lanbat.hosts name;
          remoteBuild = hostCfg.system == "aarch64-linux";
        in
        lib.nameValuePair flakeName {
          hostname = hostIp;
          sshUser = "admin";
          user = "root";
          profiles.system.path = (deployLib hostCfg.system).activate.nixos hosts.${name};
        }
        // lib.optionalAttrs remoteBuild {
          remoteBuild = true;
        }
      ) deploy'.hosts;
    in
    {
      inherit profileName;
      configurations = configurations;
      deployNodes = deployNodes;
    };

  profileResults = lib.mapAttrs mkProfile profiles;

  configurations = lib.foldl' lib.recursiveUpdate { } (
    map (result: result.configurations) (lib.attrValues profileResults)
  );

  deployNodes = lib.foldl' lib.recursiveUpdate { } (
    map (result: result.deployNodes) (lib.attrValues profileResults)
  );

  deployLib =
    system:
    (import nixpkgs {
      inherit system;
      overlays = [
        deploy-rs.overlays.default
        (final: prev: {
          deploy-rs = {
            inherit (nixpkgs.legacyPackages.${system}) deploy-rs;
            inherit (prev.deploy-rs) lib;
          };
        })
      ];
    }).deploy-rs.lib;

in
{
  inherit (hostLib) hostsWithRole primaryHost hostIp hostHostname hostInterface voiceRoomForHost;
  inherit (pluginLib) knownRoles validatePlugin resolvePlugins;

  mkHost = mkHost;
  mkProfile = mkProfile;
  hostFlakeName = hostFlakeName;
  configurations = configurations;
  deployNodes = deployNodes;
  profileResults = profileResults;
  deployLib = deployLib;
  deployQuery = deployQueryLib.query;
}
