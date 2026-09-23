# lib/validate-deploy.nix
#
# Pure deploy/profile validation. NFS storageHost checks are service-level; not
# validated here.
{ lib }:

let
  hostLib = import ./host.nix { inherit lib; };
  pluginLib = import ./plugins.nix { inherit lib; };

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

  validateRoleRequirements =
    profileName: hostName: host:
    let
      ctx = "profile '${profileName}', host '${hostName}'";
    in
    if host.role == "server" then
      if !(host ? disks) || !(host.disks ? system) then
        builtins.throw "${ctx}: server role requires disks.system"
      else
        requireNonEmptyString profileName hostName "disks.system" host.disks.system
    else if host.role == "storage-pi" then
      let
        drives = (host.storage or { }).drives or { };
        # A drive's key names its unlock unit, LUKS mapper, mount point and NFS
        # mount (storage-<key>-unlock, /mnt/storage-<key>, /srv/storage/<key>).
        # systemd escapes a "-" in a mount path, so the mount unit would no
        # longer be srv-storage-<key>.mount; keep keys to letters and digits.
        badKeys = lib.filter (key: builtins.match "[a-z0-9]+" key == null) (lib.attrNames drives);
      in
      if !(lib.isAttrs drives) || drives == { } then
        builtins.throw "${ctx}: storage-pi role requires at least one entry in storage.drives"
      else if badKeys != [ ] then
        builtins.throw "${ctx}: storage.drives keys must be lowercase letters and digits: ${lib.concatStringsSep ", " badKeys}"
      else
        lib.foldl' (
          _: key: requireNonEmptyString profileName hostName "storage.drives.${key}" drives.${key}
        ) null (lib.attrNames drives)
    else if host.role == "voice-pi" then
      null
    else
      builtins.throw "${ctx}: unknown role '${host.role}'";

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
          builtins.seq (validateRoleRequirements profileName name host) (
            pluginLib.resolvePlugins host.role (host.plugins or [ ]) (host.services or [ ])
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
    lib.foldl' (
      _: room:
      let
        hostKey = voiceRooms.${room};
        ctx = "profile '${profileName}', voiceRooms.${room}";
      in
      if !(hosts ? ${hostKey}) then
        builtins.throw "${ctx}: references unknown host '${hostKey}'"
      else if !(hasVoiceCapability hosts.${hostKey}) then
        builtins.throw "${ctx}: host '${hostKey}' must include lanbat-voice plugin or have role 'server'"
      else
        null
    ) null (lib.attrNames voiceRooms);

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
