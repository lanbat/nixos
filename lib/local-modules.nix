# lib/local-modules.nix
#
# Finds a deployment's local modules: NixOS modules a fork keeps in a
# gitignored directory, so it can change any host without editing a tracked
# file or its deploy entry.
#
#   deployments/<profile>/local/*.nix              every host of the profile
#   deployments/<profile>/local/hosts/<key>/*.nix  host <key> only
#
# Files are imported in name order, profile-wide ones first, after every other
# module source including hosts.<key>.modules. Anything that is not a .nix file
# is ignored, so a module can keep its data next to it in a subdirectory.
#
# A missing directory contributes nothing. That is also what a flake evaluated
# from git sees, since git leaves untracked files out of the source: CI and a
# git+file evaluation never pick these up, and a deployment evaluated as path:.
# does.
{ lib }:

let
  nixFilesIn =
    dir:
    if builtins.pathExists dir then
      map (name: dir + "/${name}") (
        lib.attrNames (
          lib.filterAttrs (
            name: type: lib.hasSuffix ".nix" name && (type == "regular" || type == "symlink")
          ) (builtins.readDir dir)
        )
      )
    else
      [ ];
in
{
  # root: the flake root. Returns the module paths for one host.
  localModules =
    root: profileName: hostName:
    let
      dir = root + "/deployments/${profileName}/local";
    in
    nixFilesIn dir ++ nixFilesIn (dir + "/hosts/${hostName}");
}
