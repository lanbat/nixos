# modules/wiring/caddy.nix
#
# Generates a Caddy vhost for every service with a subdomain:
#
#   <subdomain>.<domain> {
#     tls internal { on_demand }
#     forward_auth ...            # auth = "forward-auth" only
#     <caddy.extraConfig>
#     reverse_proxy localhost:<port or onDemand.activatorPort> { <caddy.proxyOptions> }
#   }
#
# Caddy itself (global options, internal CA, CA landing page) is configured
# in services/caddy.nix.
{ config, lib, ... }:

let
  domain = config.lanbat.domain;

  authentikFwdAuth = ''
    forward_auth localhost:${toString config.lanbat.services.authentik.port} {
      uri /outpost.goauthentik.io/auth/caddy
      copy_headers X-Authentik-Username X-Authentik-Groups X-Authentik-Email \
                   X-Authentik-Name X-Authentik-Uid X-Authentik-Jwt \
                   X-Authentik-Meta-Jwks X-Authentik-Meta-Outpost \
                   X-Authentik-Meta-Provider X-Authentik-Meta-App \
                   X-Authentik-Meta-Version
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

  # Companion apps and REST clients authenticate directly with HA tokens, so
  # /auth/token and /api/* bypass Authentik when apiClients is set.
  forwardAuthWithApiBypass =
    svc:
    lib.concatStringsSep "\n" [
      svc.caddy.extraConfig
      ''
        route {
          @api_clients path /auth/token* /api/*
          handle @api_clients {
            ${reverseProxy svc}
          }
          handle {
            ${authentikFwdAuth}
            ${reverseProxy svc}
          }
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
        (
          if svc.auth == "forward-auth" && svc.apiClients then
            forwardAuthWithApiBypass svc
          else
            lib.concatStringsSep "\n" (
              lib.filter (s: s != "") [
                (lib.optionalString (svc.auth == "forward-auth") authentikFwdAuth)
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
