# modules/wiring/checks.nix
#
# Evaluation-time checks on lanbat.services. A failing check stops the build
# with a message that starts with "lanbat:".
{ config, lib, ... }:

let
  services = lib.mapAttrsToList (name: svc: svc // { inherit name; }) config.lanbat.services;

  # [ { key; owner; } ] → error lines for keys claimed by more than one owner.
  clashes =
    what: claims:
    let
      byKey = lib.groupBy (c: toString c.key) claims;
      owners = lib.mapAttrs (_: cs: lib.unique (map (c: c.owner) cs)) byKey;
    in
    lib.mapAttrsToList (key: os: "lanbat: ${what} ${key} is used by ${lib.concatStringsSep ", " os}") (
      lib.filterAttrs (_: os: lib.length os > 1) owners
    );

  portClaims = lib.concatMap (
    s:
    map
      (p: {
        key = p;
        owner = s.name;
      })
      (
        lib.optional (s.port != null) s.port
        ++ lib.optional (s.onDemand != null) s.onDemand.activatorPort
        ++ s.extraPorts
      )
  ) services;

  subdomainClaims = lib.concatMap (
    s:
    lib.optional (s.subdomain != null) {
      key = s.subdomain;
      owner = s.name;
    }
  ) services;

  secretClaims = lib.concatMap (
    s:
    map (secret: {
      key = secret;
      owner = s.name;
    }) (lib.attrNames s.secrets)
  ) services;

  uidClaims = lib.mapAttrsToList (name: u: {
    key = u.uid;
    owner = name;
  }) (lib.filterAttrs (_: u: u.uid != null) config.users.users);

  gidClaims = lib.mapAttrsToList (name: g: {
    key = g.gid;
    owner = name;
  }) (lib.filterAttrs (_: g: g.gid != null) config.users.groups);

  # Gated units start with workload-online.target. A unit outside the gate that
  # pulls one in, or needs a workload directory, pulls in the workload mounts
  # too, and boot then waits for a LUKS device that only unlock-workload opens.
  workload = lib.filter (s: s.tier == "workload") services;
  gatedUnits = lib.concatMap (s: s.units) workload;
  gatedDirs = [ "/mnt/workload" ] ++ map (d: "/var/lib/${d}") (lib.concatMap (s: s.state) workload);
  onWorkload = path: lib.any (d: path == d || lib.hasPrefix "${d}/" path) gatedDirs;
  words = v: if lib.isList v then v else lib.splitString " " (toString v);

  gatedPulls = lib.concatLists (
    lib.mapAttrsToList (
      name: unit:
      map (dep: "lanbat: ${name} pulls in the workload-gated ${dep}; add ${name} to that service's units")
        (
          lib.intersectLists (map (u: "${u}.service") gatedUnits) (
            unit.wants ++ unit.requires ++ unit.bindsTo ++ unit.requisite or [ ]
          )
        )
      ++
        map
          (
            path:
            "lanbat: ${name} needs ${path}, which is on the workload layer; add ${name} to that service's units"
          )
          (
            lib.filter onWorkload (
              words (unit.unitConfig.RequiresMountsFor or [ ])
              ++ words (unit.serviceConfig.WorkingDirectory or [ ])
              ++ map (d: "/var/lib/${d}") (words (unit.serviceConfig.StateDirectory or [ ]))
            )
          )
    ) (removeAttrs config.systemd.services gatedUnits)
  );

  # A timer, socket or path unit starts the service of the same name, so for a
  # gated service it has to start with the layer rather than at boot.
  ungatedTriggers =
    lib.concatMap
      (
        kind:
        map
          (
            name:
            "lanbat: ${name}.${kind} starts the workload-gated ${name}.service outside the gate; set systemd.${kind}s.${name}.wantedBy to [ \"workload-online.target\" ]"
          )
          (
            lib.filter (
              name: lib.any (t: t != "workload-online.target") config.systemd."${kind}s".${name}.wantedBy
            ) (lib.intersectLists gatedUnits (lib.attrNames config.systemd."${kind}s"))
          )
      )
      [
        "timer"
        "socket"
        "path"
      ];

  # Units the wiring attaches to must be defined by some module, or the
  # generated overrides create empty units that fail at runtime.
  referencedUnits = lib.concatMap (
    s:
    map
      (unit: {
        inherit unit;
        owner = s.name;
      })
      (
        lib.optionals (s.tier == "workload") s.units
        ++ s.nfs.units
        ++ lib.optional (s.onDemand != null) (lib.removeSuffix ".service" s.onDemand.unit)
      )
  ) services;

  undefinedUnits = lib.filter (
    r: (config.systemd.services.${r.unit}.serviceConfig.ExecStart or null) == null
  ) referencedUnits;

  perService = s: [
    {
      assertion = !(s.auth == "forward-auth" && s.apiClients);
      message = "lanbat: ${s.name} has API clients, so it can't use forward auth (clients can't pass the Authentik login)";
    }
    {
      assertion = s.auth != "forward-auth" || config.lanbat.services ? authentik;
      message = "lanbat: ${s.name} uses forward auth, but the authentik service isn't imported";
    }
    {
      assertion = s.tier != "workload" || s.state != [ ];
      message = "lanbat: ${s.name} is workload-gated but declares no state; list its /var/lib directories in state";
    }
    {
      assertion = s.tier != "workload" || s.units != [ ];
      message = "lanbat: ${s.name} is workload-gated but declares no units to gate";
    }
    {
      assertion = s.tier == "workload" || (s.state == [ ] && s.workloadDirs == { });
      message = "lanbat: ${s.name} declares state or workloadDirs but isn't workload-gated; set tier = \"workload\"";
    }
    {
      assertion = s.nfs.drives == [ ] || s.nfs.units != [ ];
      message = "lanbat: ${s.name} uses Pi storage but declares no units to stop when it disappears";
    }
    {
      assertion = s.onDemand == null || s.port != null;
      message = "lanbat: ${s.name} is on-demand but has no port for the activator to proxy to";
    }
    {
      assertion = s.subdomain == null || s.port != null || s.caddy.extraConfig != "";
      message = "lanbat: ${s.name} has a subdomain but neither a port nor caddy.extraConfig";
    }
    {
      assertion = s.dashboard == null || s.subdomain != null;
      message = "lanbat: ${s.name} is on the dashboard but has no subdomain to link to";
    }
  ];

  errors =
    clashes "port" portClaims
    ++ clashes "subdomain" subdomainClaims
    ++ clashes "secret" secretClaims
    ++ clashes "UID" uidClaims
    ++ clashes "GID" gidClaims
    ++ map (r: "lanbat: ${r.owner} references unit ${r.unit}, which no module defines") undefinedUnits
    ++ gatedPulls
    ++ ungatedTriggers;
in
{
  assertions =
    lib.concatMap perService services
    ++ map (message: {
      assertion = false;
      inherit message;
    }) errors;
}
