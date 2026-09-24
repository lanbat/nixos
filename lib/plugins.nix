# lib/plugins.nix
#
# Validates and resolves lanbat plugins for a host.
#
# Two contract versions load. Version 2 is current:
#
#   {
#     name = "lanbat-media";
#     version = 2;
#     roles = [ "server" ];
#     modules = [ ./common.nix ];                  # always imported (optional)
#     services = { jellyfin = ./jellyfin.nix; };   # placement registry (optional)
#     settings = {                                 # deployment namespaces (optional)
#       media = lib: lib.mkOption { ... };         # → lanbat.deployment.media
#     };
#   }
#
# Version 1 plugins, which predate services and settings being part of the
# contract, keep loading with their old meaning: modules is everything the
# plugin contributes, and an undocumented services attribute, when present,
# is the subset a host can select by name. A host that enables one gets an
# evaluation warning pointing at docs/plugins.md.
{ lib }:

let
  knownRoles = [
    "server"
    "storage-pi"
    "voice-pi"
  ];

  supportedVersions = [
    1
    2
  ];

  v2Fields = [
    "name"
    "version"
    "roles"
    "modules"
    "services"
    "settings"
  ];

  describe = plugin: "lanbat plugin '${plugin.name or "unknown"}'";

  validateV1 =
    plugin:
    if plugin ? settings then
      builtins.throw (
        "${describe plugin} declares settings, which contract version 1 does not have."
        + " Set version = 2 (see docs/plugins.md)."
      )
    else if plugin.modules == [ ] then
      builtins.throw "${describe plugin} must declare at least one module"
    else
      plugin;

  validateV2 =
    plugin:
    let
      unknown = lib.filter (field: !(lib.elem field v2Fields)) (lib.attrNames plugin);
      badSettings = lib.filter (ns: !(lib.isFunction plugin.settings.${ns})) (
        lib.attrNames (plugin.settings or { })
      );
    in
    if unknown != [ ] then
      builtins.throw (
        "${describe plugin} has unknown field(s): "
        + lib.concatStringsSep ", " unknown
        + ". Contract version 2 knows: "
        + lib.concatStringsSep ", " v2Fields
        + "."
      )
    else if (plugin.modules or [ ]) == [ ] && (plugin.services or { }) == { } then
      builtins.throw "${describe plugin} must declare at least one module or service"
    else if badSettings != [ ] then
      builtins.throw (
        "${describe plugin}: settings."
        + lib.concatStringsSep ", settings." badSettings
        + " must be a function from lib to an option (lib: lib.mkOption { ... })"
      )
    else
      plugin;

  validatePlugin =
    plugin:
    let
      missing = lib.filter (field: !(plugin ? ${field})) (
        [
          "name"
          "version"
          "roles"
        ]
        ++ lib.optional ((plugin.version or null) == 1) "modules"
      );
    in
    if missing != [ ] then
      builtins.throw "${describe plugin} is missing fields: ${lib.concatStringsSep ", " missing}"
    else if plugin.version == 1 then
      validateV1 plugin
    else if plugin.version == 2 then
      validateV2 plugin
    else
      builtins.throw (
        "${describe plugin} has contract version ${builtins.toJSON plugin.version}; this lanbat"
        + " loads versions ${lib.concatMapStringsSep " and " toString supportedVersions}."
        + " Update lanbat, or pin the plugin to a release written for it."
      );

  # Services a plugin offers by name, for a host to pick from. A version 1
  # plugin without a services attribute is all-or-nothing and contributes
  # every module it has.
  offeredServices =
    validated:
    lib.foldl' (
      acc: p:
      let
        clashing = lib.attrNames (lib.intersectAttrs (p.services or { }) acc);
      in
      if clashing != [ ] then
        builtins.throw (
          "plugin '${p.name}' offers service(s) another plugin already offers: "
          + lib.concatStringsSep ", " clashing
        )
      else
        acc // (p.services or { })
    ) { } validated;

  # An empty selection means the host takes everything its plugins offer, so a
  # deploy entry that names no services keeps working unchanged.
  resolvePlugins =
    hostRole: plugins: selected:
    let
      validated = map validatePlugin plugins;
      incompatible = lib.filter (p: !(lib.elem hostRole p.roles)) validated;
      available = offeredServices validated;
      unknown = lib.filter (name: !(available ? ${name})) selected;
      # A plugin may offer no services at all (a version 2 plugin with only
      # modules), so an absent services attribute offers nothing to select.
      selectedOf =
        p:
        let
          offered = p.services or { };
        in
        map (name: offered.${name}) (lib.filter (name: offered ? ${name}) selected);
      modulesFor =
        p:
        if p.version == 1 then
          if selected == [ ] || !(p ? services) then p.modules else selectedOf p
        else
          (p.modules or [ ])
          ++ (if selected == [ ] then lib.attrValues (p.services or { }) else selectedOf p);
    in
    if incompatible != [ ] then
      builtins.throw (
        "plugin(s) incompatible with role '${hostRole}': "
        + lib.concatStringsSep ", " (map (p: p.name) incompatible)
      )
    else if unknown != [ ] then
      builtins.throw (
        "no enabled plugin offers service(s): "
        + lib.concatStringsSep ", " unknown
        + (
          if available == { } then
            " (no plugin on this host offers any service)"
          else
            "; available: " + lib.concatStringsSep ", " (lib.attrNames available)
        )
      )
    else
      lib.concatLists (map modulesFor validated);

  # The deployment namespaces the plugins of a whole profile declare, as
  # modules to import on every host of that profile. Deployment settings are
  # profile-wide, so a host without the plugin still has to accept the values a
  # deploy file sets for it. The same plugin enabled on several hosts counts
  # once; two plugins claiming one namespace is an error naming both.
  settingsModules =
    plugins:
    let
      byName = lib.foldl' (acc: p: acc // { ${p.name} = p; }) { } (map validatePlugin plugins);
      claims = lib.concatMap (
        p:
        map (ns: {
          inherit ns;
          plugin = p.name;
        }) (lib.attrNames (p.settings or { }))
      ) (lib.attrValues byName);
      owners = lib.mapAttrs (_: cs: map (c: c.plugin) cs) (lib.groupBy (c: c.ns) claims);
      clashing = lib.filterAttrs (_: ps: lib.length ps > 1) owners;
    in
    if clashing != { } then
      builtins.throw (
        "lanbat plugins declare the same deployment setting: "
        + lib.concatStringsSep "; " (
          lib.mapAttrsToList (ns: ps: "${ns} by ${lib.concatStringsSep ", " ps}") clashing
        )
      )
    else
      map (
        c:
        let
          declare = byName.${c.plugin}.settings.${c.ns};
        in
        {
          # Names the plugin in the module system's own errors, such as a
          # namespace that core already declares.
          _file = "lanbat plugin '${c.plugin}' (settings.${c.ns})";
          imports = [
            (
              { lib, ... }:
              {
                options.lanbat.deployment.${c.ns} = declare lib;
              }
            )
          ];
        }
      ) claims;

  # Names of the version 1 plugins among these, for the deprecation warning.
  legacyPlugins = plugins: map (p: p.name) (lib.filter (p: (p.version or null) == 1) plugins);

in
{
  inherit
    knownRoles
    supportedVersions
    validatePlugin
    resolvePlugins
    offeredServices
    settingsModules
    legacyPlugins
    ;
}
