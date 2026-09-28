# modules/wiring/caddy.nix
#
# Generates a Caddy vhost for every service with a subdomain:
#
#   <subdomain>.<domain> {
#     tls internal { on_demand }
#     route {                     # auth = "forward-auth" only
#       <authProvider.outpostProxy>
#       <authProvider.forwardAuth>
#       <caddy.extraConfig>
#       reverse_proxy <upstream>
#     }
#   }
#
# The upstream is localhost:<port> for a service on this host. A Caddy host
# also serves the subdomain of every service that runs only on other hosts,
# from the profile-wide table: the upstream is then that host at the service's
# endpoint port, reached through lanbat.endpointHost, so it is the overlay name
# or LAN address the providing host's generated firewall rule admits. That rule
# admits this host because lib/endpoints.nix proxyHostsOf counts it as a
# consumer; the vhosts below come from the same function, so the two agree.
#
# A remote service must run on exactly one host (a vhost has one upstream; a
# copy on this host wins, as it always has), publish an http or https
# endpoint, and not be on-demand (its activator exists only on its own host and
# is not part of its endpoint). Its caddy.extraConfig and proxyOptions run on
# this host, so they must not reach localhost. Evaluation rejects each case.
#
# What the authentication check looks like comes from lanbat.authProvider, the
# contract in modules/core/auth.nix, so nothing here names a provider.
#
# Caddy itself (global options, internal CA, CA landing page) is configured
# in services/caddy.nix.
{ config, lib, ... }:

let
  domain = config.lanbat.deployment.domain;

  # Resolved per service rather than in a let binding, so that a host with no
  # provider is told which service wanted one instead of failing while this
  # file is still being evaluated.
  authProviderFor =
    svc:
    if config.lanbat.authProvider != null then
      config.lanbat.authProvider
    else
      throw (
        "lanbat: ${svc.name} is set to auth = \"forward-auth\", but no"
        + " authentication provider runs on this host. Add one to this host's"
        + " services, or set ${svc.name}'s auth to \"app\" or \"none\"."
      );

  upstreamPort = svc: if svc.onDemand != null then svc.onDemand.activatorPort else svc.port;

  reverseProxy =
    svc:
    if svc.upstream == null then
      ""
    else if svc.caddy.proxyOptions == "" then
      "reverse_proxy ${svc.upstream}"
    else
      ''
        reverse_proxy ${svc.upstream} {
        ${svc.caddy.proxyOptions}
        }
      '';

  errorPage = svc: if svc.nfs.drives != [ ] then "storage.html" else "offline.html";

  handleErrors = svc: ''
    handle_errors 502 503 504 {
      rewrite * /${errorPage svc}
      file_server {
        root /var/lib/caddy-error-pages
      }
    }
  '';

  # Companion apps and REST clients authenticate directly with the app (HA
  # tokens, Immich API keys), so /auth/token, /api/* and the Immich app's
  # server discovery (/.well-known/immich) bypass Authentik when apiClients
  # is set.  Per-service caddy.authBypassPaths adds more (Music Assistant
  # needs /info and /ws so its UI can auto-connect behind the proxy).
  authBypassPaths =
    svc:
    (lib.optionals svc.apiClients [
      "/auth/token*"
      "/api/*"
      "/.well-known/immich"
    ])
    ++ svc.caddy.authBypassPaths;

  forwardAuthWithApiBypass =
    svc:
    let
      paths = authBypassPaths svc;
      # One `path` directive with multiple arguments (OR). Repeated `path`
      # keywords would AND and never match.
      pathMatcher = lib.concatStringsSep " " paths;
    in
    lib.concatStringsSep "\n" [
      ''
        route {
          ${(authProviderFor svc).outpostProxy}
          @auth_bypass path ${pathMatcher}
          handle @auth_bypass {
            ${reverseProxy svc}
          }
          handle {
            ${(authProviderFor svc).forwardAuth}
            ${svc.caddy.extraConfig}
            ${reverseProxy svc}
          }
        }
      ''
    ];

  forwardAuthRoute =
    svc:
    lib.concatStringsSep "\n" [
      ''
        route {
          ${(authProviderFor svc).outpostProxy}
          ${(authProviderFor svc).forwardAuth}
          ${svc.caddy.extraConfig}
          ${reverseProxy svc}
        }
      ''
    ];

  vhost =
    svc:
    lib.concatStringsSep "\n" (
      lib.filter (s: s != "") [
        ''
          tls internal {
            on_demand
          }
        ''
        (handleErrors svc)
        (
          if svc.auth == "forward-auth" && authBypassPaths svc != [ ] then
            forwardAuthWithApiBypass svc
          else if svc.auth == "forward-auth" then
            forwardAuthRoute svc
          else
            lib.concatStringsSep "\n" (
              lib.filter (s: s != "") [
                svc.caddy.extraConfig
                (reverseProxy svc)
              ]
            )
        )
      ]
    );

  endpointLib = import ../../lib/endpoints.nix { inherit lib; };
  endpoints = config.lanbat.endpoints;
  thisHost = config.lanbat.hostKey;

  local = lib.mapAttrs (
    _: svc:
    svc
    // {
      upstream = if svc.port == null then null else "localhost:${toString (upstreamPort svc)}";
    }
  ) (lib.filterAttrs (_: svc: svc.subdomain != null) config.lanbat.services);

  # Services this host's Caddy serves from another host: exactly those whose
  # generated policy admits this host.
  remoteEntries = lib.filterAttrs (
    name: _: lib.elem thisHost (endpointLib.proxyHostsOf { inherit endpoints name; })
  ) endpoints;

  mentionsLocalhost =
    text:
    lib.any (needle: lib.hasInfix needle text) [
      "localhost"
      "127.0.0.1"
      "[::1]"
    ];

  # Why a remote service cannot be served from here, or null when it can.
  remoteProblem =
    name: entry:
    let
      where = lib.concatStringsSep ", " entry.hosts;
    in
    if lib.length entry.hosts != 1 then
      "lanbat: ${name} has a subdomain and runs on more than one host (${where}),"
      + " none of them ${thisHost}, whose Caddy serves it. A vhost proxies to one"
      + " place, and picking one would be a guess. Place it on one host, or on ${thisHost}."
    else if entry.endpoint == null then
      "lanbat: ${name} has a subdomain and runs on ${where}, but publishes no"
      + " endpoint for the Caddy on ${thisHost} to proxy to. Give it a port (or an"
      + " endpoint), or place it on ${thisHost}."
    else if entry.web.onDemand then
      "lanbat: ${name} is on-demand and runs on ${where}, but its subdomain is"
      + " served by the Caddy on ${thisHost}. The activator runs on the service's own"
      + " host and is not part of its endpoint, so it cannot be proxied to from"
      + " another host. Place ${name} on ${thisHost}, or drop onDemand."
    else if
      !(lib.elem entry.endpoint.scheme [
        "http"
        "https"
      ])
    then
      "lanbat: ${name} has a subdomain, but its endpoint on ${where} uses scheme"
      + " \"${entry.endpoint.scheme}\", which the Caddy on ${thisHost} cannot reverse"
      + " proxy. Use \"http\" or \"https\", or place it on ${thisHost}."
    else if
      mentionsLocalhost entry.web.caddy.extraConfig || mentionsLocalhost entry.web.caddy.proxyOptions
    then
      "lanbat: ${name} runs on ${where}, but its caddy.extraConfig or"
      + " caddy.proxyOptions refers to localhost, which on ${thisHost}, where its"
      + " Caddy runs, is not ${name}. Place it on ${thisHost}, or remove the"
      + " localhost reference."
    else
      null;

  remoteProblems = lib.filter (p: p != null) (lib.mapAttrsToList remoteProblem remoteEntries);

  # Only the servable ones become vhosts, so a rejected service reaches the
  # user as the assertion above rather than as an error from inside a vhost.
  remote = lib.mapAttrs (
    name: entry:
    let
      host = lib.head entry.hosts;
      scheme = lib.optionalString (entry.endpoint.scheme == "https") "https://";
    in
    entry.web
    // {
      inherit name;
      inherit (entry) nfs;
      upstream = "${scheme}${config.lanbat.endpointHost name host}:${toString entry.endpoint.port}";
    }
  ) (lib.filterAttrs (name: entry: remoteProblem name entry == null) remoteEntries);

  exposed = local // remote;

  subdomainClashes =
    lib.mapAttrsToList
      (sub: owners: "lanbat: subdomain ${sub} is used by ${lib.concatStringsSep ", " owners}")
      (
        lib.filterAttrs (_: owners: lib.length owners > 1) (
          lib.mapAttrs (_: svcs: map (svc: svc.name) svcs) (
            lib.groupBy (svc: svc.subdomain) (lib.attrValues exposed)
          )
        )
      );
in
{
  services.caddy.virtualHosts = lib.mapAttrs' (
    _: svc: lib.nameValuePair "${svc.subdomain}.${domain}" { extraConfig = vhost svc; }
  ) exposed;

  # Local subdomain clashes are reported by modules/wiring/checks.nix; only a
  # clash involving a remote service is new here.
  assertions =
    map (message: {
      assertion = false;
      inherit message;
    }) remoteProblems
    ++ lib.optionals (remote != { }) (
      map (message: {
        assertion = false;
        inherit message;
      }) subdomainClashes
    );
}
