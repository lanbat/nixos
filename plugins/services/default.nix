# plugins/services/default.nix
#
# Built-in server services plugin. The module list comes from registry.nix, so
# a host that names services in hosts.<key>.services gets just those, and a
# host that names none still gets the whole set.
let
  registry = import ./registry.nix;
in
{
  name = "lanbat-services";
  version = 1;
  roles = [ "server" ];
  modules = builtins.attrValues registry;
  services = registry;
}
