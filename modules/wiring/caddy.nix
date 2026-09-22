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
#       reverse_proxy localhost:<port>
#     }
#   }
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
    if svc.port == null then
      ""
    else if svc.caddy.proxyOptions == "" then
      "reverse_proxy localhost:${toString (upstreamPort svc)}"
    else
      ''
        reverse_proxy localhost:${toString (upstreamPort svc)} {
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

  exposed = lib.filterAttrs (_: svc: svc.subdomain != null) config.lanbat.services;
in
{
  services.caddy.virtualHosts = lib.mapAttrs' (
    _: svc: lib.nameValuePair "${svc.subdomain}.${domain}" { extraConfig = vhost svc; }
  ) exposed;
}
