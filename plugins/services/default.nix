# plugins/services/default.nix
#
# Built-in server services plugin. Every service is registered from
# registry.nix, so a host that names services in hosts.<key>.services gets just
# those, and a host that names none still gets the whole set.
{
  name = "lanbat-services";
  version = 2;
  roles = [ "server" ];
  services = import ./registry.nix;
}
