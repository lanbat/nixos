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
# unchanged when the transport between hosts changes.
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
# rather than a service, so it has no endpoint to generate from and keeps its
# literal rules. Tang publishes no endpoint either, and must not: the Pi reaches
# it to unlock its LUKS storage, and that path cannot depend on generated policy.
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

  addressOf = hostKey: config.lanbat.hosts.${hostKey}.networking.ip;

  # The rule bodies, without the -I/-D verb, so that the start and stop commands
  # cannot drift apart.
  specsFor =
    name: svc:
    let
      port = toString svc.endpoint.port;
      remote = lib.filter (h: h != thisHost) (consumerHostsOf name);
    in
    [ "INPUT -p tcp --dport ${port} ! -i lo -j DROP" ]
    ++ map (h: "INPUT -p tcp --dport ${port} -s ${addressOf h} -j ACCEPT") remote;

  specs = lib.concatLists (lib.mapAttrsToList specsFor provided);

in
{
  networking.firewall.extraCommands = lib.concatStringsSep "\n" (
    map (spec: "iptables -I ${spec}") specs
  );

  # extraCommands writes into INPUT, which the firewall's reload does not flush,
  # so without a matching delete the inserted rules accumulate on every reload.
  # services/mosquitto.nix carries the same pairing and the comment explaining
  # why. Failures are swallowed because a stop may run when the rules were never
  # inserted.
  networking.firewall.extraStopCommands = lib.concatStringsSep "\n" (
    map (spec: "iptables -D ${spec} 2>/dev/null || true") specs
  );
}
