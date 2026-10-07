# plugins/dns/default.nix
#
# LAN DNS: CoreDNS answering the profile's service, host and short names, with
# optional block lists (modules/core/dns.nix). Enable it on two hosts so that
# LAN DNS survives one of them rebooting; both serve identical zones.
{
  name = "lanbat-dns";
  version = 2;
  roles = [
    "server"
    "storage-pi"
    "voice-pi"
  ];
  modules = [
    ../../modules/core/dns.nix
  ];
}
