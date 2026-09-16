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
      missing =
        lib.filter (field: !(plugin ? ${field})) [
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

  resolvePlugins =
    hostRole: plugins:
    let
      validated = map validatePlugin plugins;
      incompatible =
        lib.filter (p: !(lib.elem hostRole p.roles)) validated;
    in
    if incompatible != [ ] then
      builtins.throw (
        "plugin(s) incompatible with role '${hostRole}': "
        + lib.concatStringsSep ", " (map (p: p.name) incompatible)
      )
    else
      lib.concatLists (map (p: p.modules) validated);

in
{
  knownRoles = knownRoles;
  validatePlugin = validatePlugin;
  resolvePlugins = resolvePlugins;
}
