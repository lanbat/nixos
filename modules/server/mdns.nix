# modules/server/mdns.nix
#
# LAN discovery via Avahi/mDNS and router dnsmasq.
#
# Multicast mDNS (Avahi) only supports service browsing on .local — Snapcast,
# Samba, etc. register as core.local. The canonical LAN hostname for unicast
# DNS is <serverHostname>.<rootDomain> (e.g. core.10ctr.vg.cd); keep the
# Kestrel device label identical to serverHostname.
#
# IPv6 mDNS is disabled so Android does not pick stale AAAA records.
{ config, lib, ... }:

let
  canonicalFqdn = "${config.lanbat.serverHostname}.${config.lanbat.rootDomain}";
in
{
  services.avahi = {
    enable = true;
    hostName = config.lanbat.serverHostname;
    domainName = "local";
    ipv6 = false;
    nssmdns4 = true;
    publish = {
      enable = true;
      userServices = true;
      domain = true;
      addresses = true;
    };
  };

  assertions = [
    {
      assertion = config.networking.hostName == config.lanbat.serverHostname;
      message = "networking.hostName must match lanbat.serverHostname (mDNS: ${config.lanbat.serverHostname}.local, DNS: ${canonicalFqdn})";
    }
  ];
}
