# services/authentik/yaml.nix
#
# A small YAML writer for Authentik blueprints.
#
# pkgs.formats.yaml cannot emit the custom tags blueprints rely on (!Find,
# !KeyOf, !Env), so this renders a Nix value directly. Mappings and sequences
# are written in block style; tagged values and scalars are written in flow
# style, with strings double-quoted (JSON strings are valid YAML).
#
#   tag "!KeyOf" "provider-x"                 →  !KeyOf "provider-x"
#   tag "!Find" [ "m" [ "slug" "s" ] ]        →  !Find ["m", ["slug", "s"]]
{ lib }:

let
  inherit (lib)
    attrNames
    concatMap
    concatMapStringsSep
    concatStringsSep
    elem
    filter
    head
    isAttrs
    isList
    tail
    ;

  isTagged = v: isAttrs v && v ? _yamlTag;

  # Keys a blueprint reader looks for first; the rest follow alphabetically.
  keyOrder = [
    "version"
    "metadata"
    "model"
    "id"
    "state"
    "identifiers"
    "attrs"
    "name"
    "slug"
  ];

  orderedKeys =
    attrs: filter (k: attrs ? ${k}) keyOrder ++ filter (k: !elem k keyOrder) (attrNames attrs);

  renderKey =
    k: if builtins.match "[A-Za-z_][A-Za-z0-9_./-]*" k != null then k else builtins.toJSON k;

  flow =
    v:
    if isTagged v then
      "${v._yamlTag} ${flow v.value}"
    else if isList v then
      "[" + concatMapStringsSep ", " flow v + "]"
    else if isAttrs v then
      "{" + concatMapStringsSep ", " (k: "${builtins.toJSON k}: ${flow v.${k}}") (orderedKeys v) + "}"
    else
      builtins.toJSON v;

  inline = v: isTagged v || !(isAttrs v || isList v) || v == [ ] || v == { };

  indent = map (l: "  " + l);

  # A value in block style, as a list of lines without the parent's indent.
  block =
    v:
    if isList v then
      concatMap (
        x:
        if inline x then
          [ "- ${flow x}" ]
        else
          let
            lines = block x;
          in
          [ "- ${head lines}" ] ++ indent (tail lines)
      ) v
    else if isAttrs v && !isTagged v then
      concatMap (
        k:
        let
          x = v.${k};
        in
        if inline x then [ "${renderKey k}: ${flow x}" ] else [ "${renderKey k}:" ] ++ indent (block x)
      ) (orderedKeys v)
    else
      [ (flow v) ];
in
{
  tag = name: value: {
    _yamlTag = name;
    inherit value;
  };

  render = v: concatStringsSep "\n" (block v) + "\n";
}
