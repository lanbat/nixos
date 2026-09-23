# modules/wiring/policy.nix
#
# Firewall policy generated from the service descriptions.
#
# A service that publishes an endpoint admits exactly the hosts running a
# service that declared it in consumes, and drops everything else. The rules are
# derived rather than written, so adding a host to a profile needs no firewall
# edit — which is what the hand-written allowlists in lib/roles/storage-pi.nix,
# lib/roles/voice-pi.nix and services/influxdb.nix each required.
#
# Policy is expressed against service identity rather than addresses, so it is
# unchanged when the transport between hosts changes. Only the address differs:
# an edge whose endpoint transport is "overlay", between two hosts on the
# overlay, admits the consumer's overlay address on the overlay interface
# (lanbat.overlay.addressOf); every other edge admits its LAN address. Under
# the none provider every edge is a LAN edge, so the rules are what they were
# before the overlay existed.
#
# Rule order matters and is why every rule uses -I. iptables -I inserts at the
# head of the chain, so the DROP emitted first ends up below the ACCEPTs emitted
# after it, and a packet from a declared consumer matches ACCEPT before it can
# reach the DROP.
#
# Loopback is exempt: without ! -i lo the drop catches local connections too,
# the same trap documented in services/influxdb.nix.
#
# Two things are deliberately outside this. NFS is wiring driven by nfs.drives
# rather than a service, so it has no endpoint to generate from; the storage
# Pi's role generates its rules from nfs.drives instead (lib/nfs-clients.nix).
# Tang publishes no endpoint either, and must not: the Pi reaches it to unlock
# its LUKS storage, and that path cannot depend on generated policy.
# modules/wiring/checks.nix rejects a Tang endpoint.
{ config, lib, ... }:

let
  thisHost = config.lanbat.hostKey;

  # Services on this host that publish something reachable.
  provided = lib.filterAttrs (_: svc: svc.endpoint != null) config.lanbat.services;

  # Every host running a service that declared it consumes `name`.
  consumerHostsOf =
    name:
    lib.unique (
      lib.concatLists (
        lib.mapAttrsToList (
          _: entry: if lib.elem name (entry.consumes or [ ]) then entry.hosts else [ ]
        ) config.lanbat.endpoints
      )
    );

  overlay = config.lanbat.overlay;

  lanAddressOf = hostKey: config.lanbat.hosts.${hostKey}.networking.ip;

  # Whether an edge between two hosts runs on the overlay: the endpoint must
  # ask for it and both ends must be on one. Otherwise it stays on the LAN,
  # which is also what every edge does under the none provider.
  viaOverlay =
    endpoint: a: b:
    endpoint.transport == "overlay" && overlay.onOverlay a && overlay.onOverlay b;

  # The rule bodies, without the -I/-D verb, so that the start and stop commands
  # cannot drift apart.
  specsFor =
    name: svc:
    let
      port = toString svc.endpoint.port;
      remote = lib.filter (h: h != thisHost) (consumerHostsOf name);
    in
    [ "INPUT -p tcp --dport ${port} ! -i lo -j DROP" ]
    ++ map (
      h:
      if viaOverlay svc.endpoint thisHost h then
        "INPUT -p tcp --dport ${port} -s ${overlay.addressOf h} -i ${overlay.interface} -j ACCEPT"
      else
        "INPUT -p tcp --dport ${port} -s ${lanAddressOf h} -j ACCEPT"
    ) remote;

  specs = lib.concatLists (lib.mapAttrsToList specsFor provided);

in
{
  options.lanbat.endpointHost = lib.mkOption {
    type = lib.types.functionTo (lib.types.functionTo lib.types.str);
    internal = true;
    readOnly = true;
    description = ''
      Where this host reaches a service on another host, given the service's
      name and that host's key: the overlay name when the edge runs on the
      overlay, the LAN address otherwise. It makes the same choice as the rule
      generated on the providing host, so a consumer always dials the address
      that rule admits.
    '';
  };

  config.lanbat.endpointHost =
    name: hostKey:
    let
      endpoint = (config.lanbat.endpoints.${name} or { endpoint = null; }).endpoint;
    in
    if endpoint != null && viaOverlay endpoint thisHost hostKey then
      overlay.nameOf hostKey
    else
      lanAddressOf hostKey;

  config.networking.firewall.extraCommands = lib.concatStringsSep "\n" (
    map (spec: "iptables -I ${spec}") specs
  );

  # extraCommands writes into INPUT, which the firewall's reload does not flush,
  # so without a matching delete the inserted rules accumulate on every reload.
  # services/mosquitto.nix carries the same pairing and the comment explaining
  # why. Failures are swallowed because a stop may run when the rules were never
  # inserted.
  config.networking.firewall.extraStopCommands = lib.concatStringsSep "\n" (
    map (spec: "iptables -D ${spec} 2>/dev/null || true") specs
  );
}
