# lib/load-deployments.nix
#
# Normalises single- and multi-profile deploy manifests into a flat attrset of
# profiles: { <profile-name> = { deployment, hosts }; }.
{ lib }:

let
  isProfile =
    value: value ? deployment && value ? hosts;

  isMulti =
    value: value ? profiles;

  normalize =
    raw:
    if raw == null then
      { }
    else if isMulti raw then
      raw.profiles
    else if isProfile raw then
      {
        default = raw;
      }
    else
      builtins.throw (
        "deploy.nix must be either a profile ({ deployment, hosts }) "
        + "or a multi-profile manifest ({ profiles = { ... }; })"
      );
in
{
  normalize = normalize;
}
