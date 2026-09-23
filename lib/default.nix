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
  endpointLib = import ./endpoints.nix { inherit lib; };

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

      endpoints = endpointLib.mkTable {
        inherit profileName described;
        hosts = deploy'.hosts;
      };

      built = lib.mapAttrs (name: cfg: mkHost profileName deploy' name cfg endpoints) deploy'.hosts;

      # The first pass runs with an empty table, so a description that reads the
      # table answers differently in each pass: the table then records the first
      # answer while the host acts on the second, and the wiring is built from a
      # description nothing actually has. That is silent — it cost a live voice
      # pipeline once — so compare the two and say which service disagreed.
      #
      # Only the fields the table carries are compared. Settings and the
      # configuration body may depend on the table; these may not.
      describedFields = svc: { inherit (svc) endpoint account consumes; };

      disagreements = lib.concatLists (
        lib.mapAttrsToList (
          hostName: before:
          let
            after = built.${hostName}.config.lanbat.services;
          in
          lib.filter (x: x != null) (
            lib.mapAttrsToList (
              svcName: svc:
              if describedFields svc != describedFields after.${svcName} then "${hostName}.${svcName}" else null
            ) before
          )
        ) described
      );

      hosts =
        if disagreements != [ ] then
          builtins.throw (
            "lanbat profile '${profileName}': the description of "
            + lib.concatStringsSep ", " disagreements
            + " changed once the endpoint table was resolved. endpoint, account"
            + " and consumes are read to build that table, so they must not"
            + " depend on it — base them on deploy data instead."
          )
        else
          built;
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
