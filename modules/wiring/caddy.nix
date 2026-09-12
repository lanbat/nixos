# modules/wiring/caddy.nix
#
# Generates a Caddy vhost for every service with a subdomain:
#
#   <subdomain>.<domain> {
#     tls internal { on_demand }
#     route {                     # auth = "forward-auth" only
#       reverse_proxy /outpost.goauthentik.io/* → Authentik outpost
#       forward_auth ...
#       <caddy.extraConfig>
#       reverse_proxy localhost:<port>
#     }
#   }
#
# Caddy itself (global options, internal CA, CA landing page) is configured
# in services/caddy.nix.
{ config, lib, ... }:

let
  domain = config.lanbat.domain;
  authentikPort = config.lanbat.services.authentik.port;

  # OAuth callback after login — must hit the outpost, not the backend app.
  authentikOutpostProxy =
    "reverse_proxy /outpost.goauthentik.io/* localhost:${toString authentikPort}";

  authentikFwdAuth = ''
    forward_auth localhost:${toString authentikPort} {
      uri /outpost.goauthentik.io/auth/caddy
      copy_headers X-Authentik-Username X-Authentik-Groups X-Authentik-Entitlements X-Authentik-Email \
                   X-Authentik-Name X-Authentik-Uid X-Authentik-Jwt \
                   X-Authentik-Meta-Jwks X-Authentik-Meta-Outpost \
                   X-Authentik-Meta-Provider X-Authentik-Meta-App \
                   X-Authentik-Meta-Version
      trusted_proxies private_ranges
    }
  '';

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
    handle_errors {
      @upstream `{http.error.status_code}` >= 502 && `{http.error.status_code}` <= 504
      rewrite @upstream /${errorPage svc}
      file_server {
        root /var/lib/caddy-error-pages
      }
    }
  '';

  # Companion apps and REST clients authenticate directly with HA tokens, so
  # /auth/token and /api/* bypass Authentik when apiClients is set.
  forwardAuthWithApiBypass =
    svc:
    lib.concatStringsSep "\n" [
      ''
        route {
          ${authentikOutpostProxy}
          @api_clients path /auth/token* /api/*
          handle @api_clients {
            ${reverseProxy svc}
          }
          handle {
            ${authentikFwdAuth}
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
          ${authentikOutpostProxy}
          ${authentikFwdAuth}
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
          if svc.auth == "forward-auth" && svc.apiClients then
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
