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
    profileName: hostName: if profileName == "default" then hostName else "${profileName}-${hostName}";

  deployQueryLib = import ./deploy-query.nix {
    inherit
      lib
      profiles
      hasDeploy
      root
      hostLib
      hostFlakeName
      ;
  };

  mkHost =
    profileName: deploy: hostName: hostCfg: endpoints:
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
        endpoints
        ;
      deployment = deploy.deployment;
      hosts = deploy.hosts;
    };

  mkProfile =
    profileName: deploy:
    let
      deploy' = validateLib.validateDeploy {
        inherit profileName;
        deploy = deploy;
      };
      # First pass: the service descriptions only, built with an empty endpoint
      # table so that nothing in them can depend on the table being resolved.
      # Reading lanbat.services forces the descriptions and not the units
      # behind them, which is what keeps this cheap enough to do every time.
      described = lib.mapAttrs (
        name: cfg: (mkHost profileName deploy' name cfg { }).config.lanbat.services
      ) deploy'.hosts;

      # The profile-wide table. A service is keyed by name and may run on more
      # than one host: telegraf and the voice satellite are per-host agents,
      # not singletons, so this records every placement rather than assuming
      # one.
      placedOn =
        svcName: lib.filter (hostName: described.${hostName} ? ${svcName}) (lib.attrNames described);

      allServiceNames = lib.unique (lib.concatMap lib.attrNames (lib.attrValues described));

      endpoints = lib.listToAttrs (
        map (
          svcName:
          let
            hostNames = placedOn svcName;
            # endpoint and account come from the service module, so every
            # placement agrees on them; take the first and check the rest.
            first = described.${lib.head hostNames}.${svcName};
            disagreeing = lib.filter (
              hostName:
              described.${hostName}.${svcName}.endpoint != first.endpoint
              || described.${hostName}.${svcName}.account != first.account
            ) hostNames;
          in
          lib.nameValuePair svcName (
            if disagreeing != [ ] then
              builtins.throw (
                "lanbat profile '${profileName}': service '${svcName}' describes a"
                + " different endpoint or account on ${lib.concatStringsSep ", " disagreeing}"
                + " than on ${lib.head hostNames}. A service must look the same"
                + " wherever it runs, or consumers cannot resolve it."
              )
            else
              {
                hosts = hostNames;
                addresses = lib.listToAttrs (
                  map (hostName: lib.nameValuePair hostName deploy'.hosts.${hostName}.networking.ip) hostNames
                );
                hostnames = lib.listToAttrs (
                  map (hostName: lib.nameValuePair hostName deploy'.hosts.${hostName}.networking.hostname) hostNames
                );
                inherit (first) endpoint account;
              }
          )
        ) allServiceNames
      );

      hosts = lib.mapAttrs (name: cfg: mkHost profileName deploy' name cfg endpoints) deploy'.hosts;
      configurations = lib.mapAttrs' (
        name: cfg: lib.nameValuePair (hostFlakeName profileName name) cfg
      ) hosts;
      deployNodes = lib.mapAttrs' (
        name: hostCfg:
        let
          flakeName = hostFlakeName profileName name;
          cfg = hosts.${name}.config;
          hostIp = hostLib.hostIp cfg.lanbat.hosts name;
          remoteBuild = hostCfg.system == "aarch64-linux";
          node = {
            hostname = hostIp;
            sshUser = "admin";
            user = "root";
            profiles.system.path = (deployLib hostCfg.system).activate.nixos hosts.${name};
          }
          // lib.optionalAttrs remoteBuild {
            remoteBuild = true;
          };
        in
        lib.nameValuePair flakeName node
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
  inherit (hostLib)
    hostsWithRole
    primaryHost
    hostIp
    hostHostname
    hostInterface
    voiceRoomForHost
    ;
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
