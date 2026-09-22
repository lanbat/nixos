# lib/plugins.nix
#
# Validates and resolves lanbat plugins for a host.
{ lib }:

let
  knownRoles = [
    "server"
    "storage-pi"
    "voice-pi"
  ];

  validatePlugin =
    plugin:
    let
      missing = lib.filter (field: !(plugin ? ${field})) [
        "name"
        "version"
        "roles"
        "modules"
      ];
    in
    if missing != [ ] then
      builtins.throw "lanbat plugin '${plugin.name or "unknown"}' is missing fields: ${lib.concatStringsSep ", " missing}"
    else if !(plugin.modules != [ ]) then
      builtins.throw "lanbat plugin '${plugin.name}' must declare at least one module"
    else
      plugin;

  # Services a plugin offers by name, for a host to pick from. A plugin without
  # a services attribute is all-or-nothing and contributes every module it has.
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
      modulesFor =
        p:
        if selected == [ ] || !(p ? services) then
          p.modules
        else
          map (name: p.services.${name}) (lib.filter (name: p.services ? ${name}) selected);
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

in
{
  knownRoles = knownRoles;
  validatePlugin = validatePlugin;
  resolvePlugins = resolvePlugins;
  offeredServices = offeredServices;
}
