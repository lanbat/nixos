# modules/overlay/wireguard-mesh.nix
#
# The overlay contract answered by a WireGuard mesh.
#
# Every host with an overlay block in deploy.nix gets one interface, and a peer
# entry for every other such host. Addresses are declared, so they are known
# during evaluation: addressOf answers with them, and nameOf answers with
# <hostname>.<deployment.overlay.domain>, installed in networking.hosts the way
# modules/wiring/nfs.nix maps storage hosts.
#
# A host is dialled only if it declares an endpoint. Every other host keeps a
# path open toward those that do with PersistentKeepalive, so a host behind NAT
# joins by dialling out, and a rendezvous host is just a host with an endpoint.
#
# The roles run systemd-networkd, so the interface is a networkd netdev rather
# than networking.wireguard.interfaces.
#
# The overlay is not required for the host to be online. Tang and NFS stay on
# the LAN by design, and the storage Pi's unlock waits for network-online, so a
# mesh that cannot come up must not hold that back. Units that do need the
# overlay order after lanbat.overlay.unit instead.
#
# Each host's private key is secrets/overlay-<hostkey>.age. It belongs to the
# host rather than to any one service, so it is declared with age.secrets
# directly (the documented exception), resolved through the profile's secrets
# provider by lanbat.secretFile. networkd reads PrivateKeyFile as the
# systemd-network user, hence the group and 0440.
{
  config,
  lib,
  ...
}:

let
  inherit (config.lanbat) hostKey hosts;
  settings = config.lanbat.deployment.overlay;

  iface = "lanbat0";
  listenPort = 51820;
  secretName = "overlay-${hostKey}";

  onOverlay = key: (hosts.${key} or { overlay = null; }).overlay != null;
  members = lib.filterAttrs (key: _: onOverlay key) hosts;
  self = hosts.${hostKey}.overlay;
  joined = onOverlay hostKey;

  # A host outside the mesh is still reachable over the LAN, so it answers with
  # what the none provider would rather than failing.
  nameOf =
    key:
    if onOverlay key then
      "${hosts.${key}.networking.hostname}.${settings.domain}"
    else
      hosts.${key}.networking.hostname;
  addressOf = key: if onOverlay key then hosts.${key}.overlay.ip else hosts.${key}.networking.ip;

  prefixLength =
    if settings.subnet == null then "32" else lib.last (lib.splitString "/" settings.subnet);

  peers = lib.mapAttrsToList (key: host: host.overlay // { inherit key; }) (
    lib.filterAttrs (key: _: key != hostKey) members
  );

  peerSection =
    peer:
    {
      PublicKey = peer.publicKey;
      AllowedIPs = [ "${peer.ip}/32" ];
    }
    // lib.optionalAttrs (peer.endpoint != null) {
      Endpoint = peer.endpoint;
      PersistentKeepalive = 25;
    };

  duplicated =
    attr:
    let
      values = lib.mapAttrsToList (_: host: host.overlay.${attr}) members;
    in
    lib.unique (lib.filter (v: lib.count (x: x == v) values > 1) values);
in
{
  lanbat.overlay = {
    provider = "wireguard-mesh";
    interface = if joined then iface else null;
    inherit nameOf addressOf onOverlay;
    unit = if joined then "systemd-networkd-wait-online@${iface}.service" else null;
  };

  assertions = [
    {
      assertion = settings.domain != null;
      message =
        "lanbat: deployment.overlay.provider is \"wireguard-mesh\" but"
        + " deployment.overlay.domain is not set. Overlay names are"
        + " <hostname>.<domain>, so the mesh needs one.";
    }
    {
      assertion = settings.subnet != null;
      message =
        "lanbat: deployment.overlay.provider is \"wireguard-mesh\" but"
        + " deployment.overlay.subnet is not set.";
    }
    {
      assertion = duplicated "ip" == [ ];
      message = "lanbat: overlay address claimed by more than one host: ${toString (duplicated "ip")}";
    }
    {
      assertion = duplicated "publicKey" == [ ];
      message = "lanbat: overlay public key shared by more than one host; every host needs its own keypair (nix run .#overlay-keys).";
    }
  ];

  networking.hosts = lib.mkMerge (
    lib.mapAttrsToList (key: host: { ${host.overlay.ip} = [ (nameOf key) ]; }) members
  );

  age.secrets = lib.mkIf joined {
    ${secretName} = {
      file = config.lanbat.secretFile secretName;
      owner = "root";
      group = "systemd-network";
      mode = "0440";
    };
  };

  systemd.network = lib.mkIf joined {
    netdevs."40-${iface}" = {
      netdevConfig = {
        Kind = "wireguard";
        Name = iface;
      };
      wireguardConfig = {
        PrivateKeyFile = config.age.secrets.${secretName}.path;
        ListenPort = listenPort;
      };
      wireguardPeers = map peerSection peers;
    };

    networks."40-${iface}" = {
      matchConfig.Name = iface;
      address = [ "${self.ip}/${prefixLength}" ];
      # Boot, and with it the storage Pi's Tang unlock, must not wait on the
      # overlay. See the header.
      linkConfig.RequiredForOnline = "no";
    };
  };

  # WireGuard answers nothing to a packet it cannot authenticate, so the port
  # reveals no more than a closed one.
  networking.firewall.allowedUDPPorts = lib.mkIf joined [ listenPort ];
}
