# lib/validate-deploy.nix
#
# Pure deploy/profile validation. NFS storageHost checks are service-level; not
# validated here.
{ lib }:

let
  hostLib = import ./host.nix { inherit lib; };
  pluginLib = import ./plugins.nix { inherit lib; };
  rolesLib = import ./roles.nix { inherit lib; };
  platformsLib = import ./platforms.nix { inherit lib; };

  containsChangeMe =
    value:
    if lib.isString value then
      builtins.match ".*CHANGE_ME.*" value != null
    else if lib.isList value then
      lib.any containsChangeMe value
    else if lib.isAttrs value && !lib.isFunction value then
      lib.any containsChangeMe (lib.attrValues value)
    else
      false;

  requireField =
    profileName: hostName: field: host:
    if !(host ? ${field}) then
      builtins.throw "profile '${profileName}', host '${hostName}': missing '${field}'"
    else
      null;

  requireNonEmptyString =
    profileName: hostName: path: value:
    if !(lib.isString value) || value == "" then
      builtins.throw "profile '${profileName}', host '${hostName}': ${path} must be a non-empty string"
    else
      null;

  # The role table (lib/roles.nix) decides both which roles exist for this
  # host, the built-in ones and any its plugins declare, and what each one
  # requires of the deploy entry.
  validateRoleRequirements =
    profileName: hostName: host:
    let
      ctx = "profile '${profileName}', host '${hostName}'";
      roles = pluginLib.roleTable (host.plugins or [ ]);
      errors = rolesLib.requirementErrors roles host;
    in
    if !(roles ? ${host.role}) then
      builtins.throw "${ctx}: unknown role '${host.role}'; known roles: ${lib.concatStringsSep ", " (lib.attrNames roles)}"
    else if errors != [ ] then
      builtins.throw "${ctx}: ${lib.concatStringsSep "; " errors}"
    else
      # A roleModules entry naming a module the role does not bundle.
      builtins.seq (lib.length (
        rolesLib.resolveRoleModules roles host.role (host.roleModules or { })
      )) null;

  # The platform table (lib/platforms.nix) decides which boards exist and the
  # system each one runs.
  validatePlatform =
    profileName: hostName: host:
    let
      errors = platformsLib.problems host;
    in
    if errors != [ ] then
      builtins.throw "profile '${profileName}', host '${hostName}': ${lib.concatStringsSep "; " errors}"
    else
      null;

  validateNetworking =
    profileName: name: host:
    let
      ctx = "profile '${profileName}', host '${name}'";
    in
    if !(host ? networking) then
      builtins.throw "${ctx}: missing 'networking'"
    else
      builtins.seq (requireNonEmptyString profileName name "networking.ip" host.networking.ip) (
        builtins.seq (requireNonEmptyString profileName name "networking.interface"
          host.networking.interface
        ) (requireNonEmptyString profileName name "networking.hostname" host.networking.hostname)
      );

  validateHost =
    profileName: hosts: name: host:
    builtins.seq (requireField profileName name "role" host) (
      builtins.seq (requireField profileName name "system" host) (
        builtins.seq (validateNetworking profileName name host) (
          builtins.seq (validatePlatform profileName name host) (
            builtins.seq (validateRoleRequirements profileName name host) (
              pluginLib.resolvePlugins host.role (host.plugins or [ ]) (host.services or [ ])
            )
          )
        )
      )
    );

  hasVoicePlugin =
    host: lib.any (plugin: (plugin.name or "") == "lanbat-voice") (host.plugins or [ ]);

  hasVoiceCapability = host: hasVoicePlugin host || host.role == "server";

  validateHosts =
    profileName: deploy:
    lib.foldl' (_: name: validateHost profileName deploy.hosts name deploy.hosts.${name}) null (
      lib.attrNames deploy.hosts
    );

  validateVoiceRooms =
    profileName: deploy:
    let
      voiceRooms = deploy.deployment.voiceRooms or { };
      hosts = deploy.hosts;
    in
    lib.foldl'
      (
        _: entry:
        let
          inherit (entry) room hostKey;
          ctx = "profile '${profileName}', voiceRooms.${room}";
        in
        if !(hosts ? ${hostKey}) then
          builtins.throw "${ctx}: references unknown host '${hostKey}'"
        else if !(hasVoiceCapability hosts.${hostKey}) then
          builtins.throw "${ctx}: host '${hostKey}' must include lanbat-voice plugin or have role 'server'"
        else
          null
      )
      null
      (
        # One host key or a list per room.
        lib.concatMap (room: map (hostKey: { inherit room hostKey; }) (lib.toList voiceRooms.${room})) (
          lib.attrNames voiceRooms
        )
      );

  validatePrimaryHosts =
    profileName: deploy:
    let
      deployment = deploy.deployment;
      hosts = deploy.hosts;
      servers = hostLib.hostsWithRole hosts "server";
      storages = hostLib.hostsWithRole hosts "storage-pi";
    in
    if lib.length servers > 1 && (deployment.primaryServer or null) == null then
      builtins.throw "profile '${profileName}': multiple server hosts (${lib.concatStringsSep ", " servers}) but deployment.primaryServer is not set"
    else if lib.length storages > 1 && (deployment.primaryStorage or null) == null then
      builtins.throw "profile '${profileName}': multiple storage-pi hosts (${lib.concatStringsSep ", " storages}) but deployment.primaryStorage is not set"
    else
      null;

  validateDeploy =
    { profileName, deploy }:
    if containsChangeMe deploy then
      builtins.throw "profile '${profileName}': deploy contains CHANGE_ME placeholder"
    else if deploy.hosts == { } then
      builtins.throw "profile '${profileName}': hosts must not be empty"
    else
      builtins.seq (validateHosts profileName deploy) (
        builtins.seq (validateVoiceRooms profileName deploy) (
          builtins.seq (validatePrimaryHosts profileName deploy) deploy
        )
      );

in
{
  inherit validateDeploy;
}
