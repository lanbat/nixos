# lib/deploy-query.nix
#
# Query deployment values for scripts and flake apps. Reads normalized profiles
# (same source as flake.nix: deploy.nix or deployments/example/deploy.nix).
{
  lib,
  profiles,
  hasDeploy,
  root,
  hostLib,
  hostFlakeName,
}:

let
  profileNames = lib.attrNames profiles;

  defaultProfile = if profiles ? homelab then "homelab" else lib.head profileNames;

  resolveProfile =
    optionalProfile: if optionalProfile == null then defaultProfile else optionalProfile;

  deployFor = profileName: profiles.${profileName};

  serverHostName =
    deploy: deploy.deployment.primaryServer or (hostLib.primaryHost deploy.hosts "server");

  deployFilePath =
    profileName:
    if !hasDeploy then
      root + "/deployments/example/deploy.nix"
    else if profileName == "default" then
      root + "/deploy.nix"
    else if builtins.pathExists (root + "/deployments/${profileName}/deploy.nix") then
      root + "/deployments/${profileName}/deploy.nix"
    else
      root + "/deploy.nix";

  hostLines = lib.concatStringsSep "\n" (
    lib.flatten (
      lib.mapAttrsToList (
        profileName: deploy:
        lib.mapAttrsToList (
          hostName: host: "${hostFlakeName profileName hostName} ${host.networking.ip}"
        ) deploy.hosts
      ) profiles
    )
  );

  hostIpLines = lib.concatStringsSep "\n" (
    lib.flatten (
      lib.mapAttrsToList (
        profileName: deploy: lib.mapAttrsToList (hostName: host: host.networking.ip) deploy.hosts
      ) profiles
    )
  );

  query = {
    "server-ip" =
      optionalProfile:
      let
        deploy = deployFor (resolveProfile optionalProfile);
      in
      hostLib.hostIp deploy.hosts (serverHostName deploy);

    domain = optionalProfile: (deployFor (resolveProfile optionalProfile)).deployment.domain;

    profile = resolveProfile;

    # One host key per line, for nix run .#overlay-keys.
    "host-keys" =
      optionalProfile:
      lib.concatStringsSep "\n" (lib.attrNames (deployFor (resolveProfile optionalProfile)).hosts);

    "flake-server" =
      optionalProfile:
      let
        profileName = resolveProfile optionalProfile;
      in
      if profileName == "default" then "server" else "${profileName}-server";

    "immich-admin-email" =
      optionalProfile:
      let
        deploy = deployFor (resolveProfile optionalProfile);
      in
      deploy.deployment.immich.adminEmail or "";

    hosts = _: hostLines;

    "host-ips" = _: hostIpLines;

    "deploy-file" = optionalProfile: toString (deployFilePath (resolveProfile optionalProfile));
  };

in
{
  inherit query defaultProfile;
}
