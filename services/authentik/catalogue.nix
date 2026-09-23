# services/authentik/catalogue.nix
#
# The Authentik app catalogue, derived from the service descriptions.
#
# Given the lanbat.services of a host, returns the two blueprints as Nix values
# (render them with ./yaml.nix):
#
#   proxy  every service with auth = "forward-auth" gets a proxy provider in
#          forward_single mode for https://<subdomain>.<domain> and an
#          application, and the embedded outpost serves all those providers.
#   oidc   every service with an oidc description gets an OAuth2 provider with
#          the service name as client ID, and an application.
#
# Names shown in Authentik come from dashboard.name (the service name when a
# service has no dashboard entry).
#
# Identifiers are the contract with a live instance
# -------------------------------------------------
# Authentik matches blueprint entries to existing objects by their identifiers
# (provider name, application slug, the outpost's managed key). Changing how
# one is derived makes Authentik create a second object and leaves the first
# one behind, so the rules below must stay stable:
#
#   forward-auth only    provider "provider-<name>" named "<Display>",
#                        application slug "<name>"
#   OIDC only            provider "provider-<name>" named "<Display>",
#                        application slug "<name>"
#   forward-auth + OIDC  the OIDC objects keep the plain names above; the proxy
#                        objects become "provider-<name>-proxy" named
#                        "<Display> (proxy)" with slug "<name>-proxy". The OIDC
#                        application gets a blank launch URL, so the service is
#                        listed once in My applications, through the proxy.
#                        These proxy providers also carry internal_host, as they
#                        always have (forward_single mode does not use it).
#
# The OIDC client secret is read from the Authentik containers' environment
# with !Env, from the variable AUTHENTIK_<NAME>_CLIENT_SECRET (upper case,
# dashes as underscores) unless oidc.secretVariable names another.
{ lib }:

{
  domain,
  # URL of Authentik itself, for the embedded outpost.
  authentikHost,
  # config.lanbat.services of the host Authentik runs on.
  services,
}:

let
  yaml = import ./yaml.nix { inherit lib; };
  inherit (yaml) tag;

  find =
    model: field: value:
    tag "!Find" [
      model
      [
        field
        value
      ]
    ];
  keyOf = tag "!KeyOf";

  flows = {
    authorization_flow =
      find "authentik_flows.flow" "slug"
        "default-provider-authorization-implicit-consent";
    invalidation_flow = find "authentik_flows.flow" "slug" "default-provider-invalidation-flow";
  };

  displayName = svc: if svc.dashboard != null then svc.dashboard.name else svc.name;

  serviceUrl =
    svc:
    if svc.subdomain != null then
      "https://${svc.subdomain}.${domain}"
    else
      throw "lanbat: ${svc.name} needs a subdomain to be an Authentik ${
        if svc.auth == "forward-auth" then "forward-auth" else "OIDC"
      } application.";

  byName = lib.sort (a: b: a.name < b.name) (lib.attrValues services);
  proxied = lib.filter (svc: svc.auth == "forward-auth") byName;
  oidcClients = lib.filter (svc: svc.oidc != null) byName;

  hasBoth = svc: svc.auth == "forward-auth" && svc.oidc != null;
  proxySuffix = svc: lib.optionalString (hasBoth svc) "-proxy";

  proxyProviderId = svc: "provider-${svc.name}${proxySuffix svc}";
  oidcProviderId = svc: "provider-${svc.name}";

  application =
    {
      svc,
      slug,
      provider,
      extraAttrs ? { },
    }:
    {
      model = "authentik_core.application";
      state = "present";
      identifiers = { inherit slug; };
      attrs = {
        name = displayName svc;
        inherit slug;
        provider = keyOf provider;
        policy_engine_mode = "any";
      }
      // extraAttrs;
    };

  proxyEntries =
    svc:
    let
      name = displayName svc + lib.optionalString (hasBoth svc) " (proxy)";
    in
    [
      {
        model = "authentik_providers_proxy.proxyprovider";
        id = proxyProviderId svc;
        state = "present";
        identifiers = { inherit name; };
        attrs =
          flows
          // {
            inherit name;
            mode = "forward_single";
            external_host = serviceUrl svc;
          }
          // lib.optionalAttrs (hasBoth svc && svc.port != null) {
            internal_host = "http://127.0.0.1:${toString svc.port}";
          };
      }
      (application {
        inherit svc;
        slug = svc.name + proxySuffix svc;
        provider = proxyProviderId svc;
      })
    ];

  secretVariable =
    svc:
    if svc.oidc.secretVariable != null then
      svc.oidc.secretVariable
    else
      "AUTHENTIK_${lib.toUpper (lib.replaceStrings [ "-" ] [ "_" ] svc.name)}_CLIENT_SECRET";

  oidcEntries = svc: [
    {
      model = "authentik_providers_oauth2.oauth2provider";
      id = oidcProviderId svc;
      state = "present";
      identifiers.name = displayName svc;
      attrs = flows // {
        name = displayName svc;
        client_id = svc.name;
        client_secret = tag "!Env" (secretVariable svc);
        client_type = "confidential";
        redirect_uris = map (url: {
          inherit url;
          matching_mode = "strict";
        }) (map (path: serviceUrl svc + path) svc.oidc.redirectPaths ++ svc.oidc.redirectUris);
        signing_key = find "authentik_crypto.certificatekeypair" "name" "authentik Self-signed Certificate";
        sub_mode = "hashed_user_id";
        include_claims_in_id_token = true;
        property_mappings = map (find "authentik_providers_oauth2.scopemapping" "scope_name") [
          "openid"
          "email"
          "profile"
        ];
      };
    }
    (application {
      inherit svc;
      slug = svc.name;
      provider = oidcProviderId svc;
      # Listed once in My applications, through its proxy application.
      extraAttrs = lib.optionalAttrs (hasBoth svc) { meta_launch_url = "blank://blank"; };
    })
  ];

  blueprint = name: entries: {
    version = 1;
    metadata = {
      inherit name;
      labels."blueprints.goauthentik.io/instantiate" = "true";
    };
    inherit entries;
  };
in
{
  proxy = blueprint "Homelab Proxy Providers" (
    lib.concatMap proxyEntries proxied
    ++ [
      # Only the providers (and the host the outpost redirects to) are set, so
      # the rest of the embedded outpost's configuration is left as it is.
      {
        model = "authentik_outposts.outpost";
        state = "present";
        identifiers.managed = "goauthentik.io/outposts/embedded";
        attrs = {
          type = "proxy";
          config.authentik_host = authentikHost;
          providers = map (svc: keyOf (proxyProviderId svc)) proxied;
        };
      }
    ]
  );

  oidc = blueprint "Homelab OIDC Providers" (lib.concatMap oidcEntries oidcClients);
}
