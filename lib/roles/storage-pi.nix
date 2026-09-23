# lib/roles/storage-pi.nix
#
# Storage Pi role: encrypted NVMe drives, NFS export, optional TV/voice plugins.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  host = config.lanbat.hosts.${config.lanbat.hostKey};
  net = host.networking;
  networkLib = import ../network.nix { inherit lib; };
  prefixLength = networkLib.prefixLengthFromCidr config.lanbat.deployment.lanSubnet;

  # Only the hosts that mount this Pi's drives may reach NFS, the same hosts
  # modules/pi/nfs-exports.nix exports to.
  nfsClients = (import ../nfs-clients.nix { inherit config lib; }).addresses;

  # The rule bodies, without the -I/-D verb, so that the start and stop commands
  # cannot drift apart. A single client keeps the one-rule form it has always
  # had. Otherwise each client gets an ACCEPT over a DROP, as
  # modules/wiring/policy.nix does it: -I inserts at the head of the chain, so
  # the ACCEPTs emitted after the DROP end up above it. With no client at all
  # only the DROP remains.
  nfsSpecs =
    if lib.length nfsClients == 1 then
      map (proto: "INPUT -p ${proto} --dport 2049 ! -s ${lib.head nfsClients} -j DROP") [
        "tcp"
        "udp"
      ]
    else
      lib.concatMap
        (
          proto:
          [ "INPUT -p ${proto} --dport 2049 ! -i lo -j DROP" ]
          ++ map (address: "INPUT -p ${proto} --dport 2049 -s ${address} -j ACCEPT") nfsClients
        )
        [
          "tcp"
          "udp"
        ];
in
{
  networking.hostName = net.hostname;

  # The Pi reboots cleanly (Clevis/Tang unlocks LUKS), so it may auto-reboot
  # within the nightly window.
  system.autoUpgrade = {
    enable = true;
    allowReboot = true;
    rebootWindow = {
      lower = "04:00";
      upper = "06:00";
    };
  };

  networking = {
    useNetworkd = true;
    interfaces.${net.interface} = {
      useDHCP = false;
      ipv4.addresses = [
        {
          address = net.ip;
          inherit prefixLength;
        }
      ];
    };
    defaultGateway = {
      address = config.lanbat.deployment.gatewayIp;
      interface = net.interface;
    };
    nameservers = [ config.lanbat.deployment.gatewayIp ];
  };

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      22
      2049
      111
    ];
    allowedUDPPorts = [ 5353 ];
    # NFS is wiring driven by nfs.drives rather than a service, so it publishes
    # no endpoint for modules/wiring/policy.nix to generate from. Its rules are
    # generated here instead, from the services that declare nfs.drives on this
    # host. The voice satellite does publish an endpoint, so policy.nix
    # generates its rule from the declared edge.
    extraCommands = lib.concatMapStrings (spec: "iptables -I ${spec}\n") nfsSpecs;
    # extraCommands writes into INPUT, which the firewall's reload does not
    # flush, so without these the rules above are inserted again on every
    # reload. Three copies had accumulated on the live Pi before this was
    # noticed. Failures are swallowed: a stop may run when they were never
    # inserted.
    extraStopCommands = lib.concatMapStrings (
      spec: "iptables -D ${spec} 2>/dev/null || true\n"
    ) nfsSpecs;
  };

  services.timesyncd.enable = true;

  environment.systemPackages = with pkgs; [
    clevis
    tang
    nfs-utils
    xfsprogs
    cryptsetup
    smartmontools
  ];

  boot.loader.grub.enable = false;

  system.stateVersion = "24.11";
}
