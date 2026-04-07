# hosts/server/services/authentik-blueprints.nix
#
# Authentik blueprints — declarative providers, applications, and outpost.
#
# Applied automatically by Authentik on startup from /blueprints/custom/.
# State is "present" (idempotent create/update) throughout.
#
# Proxy providers (forward auth via Caddy):
#   Frigate, qBittorrent, Bitmagnet, Syncthing, Snapcast, Zigbee2MQTT
#
# OIDC providers (native SSO):
#   Grafana, Nextcloud, Immich, Home Assistant, Jellyfin
#
# Secrets
# -------
# OIDC client secrets are stored in authentik-oidc-secrets.age and injected
# into the authentik containers via environmentFiles.  The blueprint reads
# them with the !Env tag so they never appear in the Nix store.
#
# File format for authentik-oidc-secrets.age (one KEY=value per line):
#   AUTHENTIK_GRAFANA_CLIENT_SECRET=<40+ random chars>
#   AUTHENTIK_NEXTCLOUD_CLIENT_SECRET=<40+ random chars>
#   AUTHENTIK_IMMICH_CLIENT_SECRET=<40+ random chars>
#   AUTHENTIK_HA_CLIENT_SECRET=<40+ random chars>
#   AUTHENTIK_JELLYFIN_CLIENT_SECRET=<40+ random chars>
#
# Each secret must also appear in the corresponding service env file so the
# service side knows the shared secret:
#   grafana-env.age       → GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=<grafana-value>
#   nextcloud-oidc-env.age → NEXTCLOUD_OIDC_CLIENT_ID=nextcloud
#                            NEXTCLOUD_OIDC_CLIENT_SECRET=<nextcloud-value>
#   immich-oidc-env.age   → IMMICH_OAUTH_CLIENT_ID=immich
#                            IMMICH_OAUTH_CLIENT_SECRET=<immich-value>
#
# Home Assistant and Jellyfin require manual UI setup on their side:
#   HA:      Settings → Devices & Services → Add Integration → search "Authentik"
#            (or use HACS: https://github.com/jchonig/ha-authentik)
#   Jellyfin: install the "SSO Authentication" plugin from the plugin catalogue,
#            then configure it with client_id="jellyfin" and the token/userinfo URLs.
{ config, pkgs, lib, ... }:

let
  domain = config.lanbat.domain;

  # ── Blueprint 1: Proxy providers (Caddy forward-auth) ─────────────────────
  proxyBlueprint = pkgs.writeText "10-proxy-providers.yaml" ''
    version: 1
    metadata:
      name: "Homelab Proxy Providers"
      labels:
        blueprints.goauthentik.io/instantiate: "true"

    entries:

      # ── Frigate ─────────────────────────────────────────────────────────────
      - model: authentik_providers_proxy.proxyprovider
        id: provider-frigate
        state: present
        identifiers:
          name: "Frigate"
        attrs:
          name: "Frigate"
          authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
          invalidation_flow: !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]
          mode: forward_single
          external_host: "https://nvr.${domain}"

      - model: authentik_core.application
        state: present
        identifiers:
          slug: frigate
        attrs:
          name: "Frigate"
          slug: frigate
          provider: !KeyOf provider-frigate
          policy_engine_mode: any

      # ── qBittorrent ─────────────────────────────────────────────────────────
      - model: authentik_providers_proxy.proxyprovider
        id: provider-qbittorrent
        state: present
        identifiers:
          name: "qBittorrent"
        attrs:
          name: "qBittorrent"
          authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
          invalidation_flow: !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]
          mode: forward_single
          external_host: "https://torrent.${domain}"

      - model: authentik_core.application
        state: present
        identifiers:
          slug: qbittorrent
        attrs:
          name: "qBittorrent"
          slug: qbittorrent
          provider: !KeyOf provider-qbittorrent
          policy_engine_mode: any

      # ── Bitmagnet ───────────────────────────────────────────────────────────
      - model: authentik_providers_proxy.proxyprovider
        id: provider-bitmagnet
        state: present
        identifiers:
          name: "Bitmagnet"
        attrs:
          name: "Bitmagnet"
          authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
          invalidation_flow: !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]
          mode: forward_single
          external_host: "https://bitmagnet.${domain}"

      - model: authentik_core.application
        state: present
        identifiers:
          slug: bitmagnet
        attrs:
          name: "Bitmagnet"
          slug: bitmagnet
          provider: !KeyOf provider-bitmagnet
          policy_engine_mode: any

      # ── Syncthing ───────────────────────────────────────────────────────────
      - model: authentik_providers_proxy.proxyprovider
        id: provider-syncthing
        state: present
        identifiers:
          name: "Syncthing"
        attrs:
          name: "Syncthing"
          authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
          invalidation_flow: !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]
          mode: forward_single
          external_host: "https://sync.${domain}"

      - model: authentik_core.application
        state: present
        identifiers:
          slug: syncthing
        attrs:
          name: "Syncthing"
          slug: syncthing
          provider: !KeyOf provider-syncthing
          policy_engine_mode: any

      # ── Snapcast ────────────────────────────────────────────────────────────
      - model: authentik_providers_proxy.proxyprovider
        id: provider-snapcast
        state: present
        identifiers:
          name: "Snapcast"
        attrs:
          name: "Snapcast"
          authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
          invalidation_flow: !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]
          mode: forward_single
          external_host: "https://audio.${domain}"

      - model: authentik_core.application
        state: present
        identifiers:
          slug: snapcast
        attrs:
          name: "Snapcast"
          slug: snapcast
          provider: !KeyOf provider-snapcast
          policy_engine_mode: any

      # ── Zigbee2MQTT ─────────────────────────────────────────────────────────
      - model: authentik_providers_proxy.proxyprovider
        id: provider-zigbee2mqtt
        state: present
        identifiers:
          name: "Zigbee2MQTT"
        attrs:
          name: "Zigbee2MQTT"
          authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
          invalidation_flow: !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]
          mode: forward_single
          external_host: "https://zigbee.${domain}"

      - model: authentik_core.application
        state: present
        identifiers:
          slug: zigbee2mqtt
        attrs:
          name: "Zigbee2MQTT"
          slug: zigbee2mqtt
          provider: !KeyOf provider-zigbee2mqtt
          policy_engine_mode: any

      # ── Embedded Outpost ────────────────────────────────────────────────────
      # Assigns all forward-auth providers to the built-in outpost that runs
      # inside authentik-server.  Only the providers field is specified so
      # the outpost's existing config (authentik_host, etc.) is preserved.
      - model: authentik_outposts.outpost
        state: present
        identifiers:
          managed: "goauthentik.io/outposts/embedded"
        attrs:
          type: proxy
          providers:
            - !KeyOf provider-frigate
            - !KeyOf provider-qbittorrent
            - !KeyOf provider-bitmagnet
            - !KeyOf provider-syncthing
            - !KeyOf provider-snapcast
            - !KeyOf provider-zigbee2mqtt
  '';

  # ── Blueprint 2: OIDC providers ───────────────────────────────────────────
  oidcBlueprint = pkgs.writeText "20-oidc-providers.yaml" ''
    version: 1
    metadata:
      name: "Homelab OIDC Providers"
      labels:
        blueprints.goauthentik.io/instantiate: "true"

    entries:

      # ── Grafana ─────────────────────────────────────────────────────────────
      - model: authentik_providers_oauth2.oauth2provider
        id: provider-grafana
        state: present
        identifiers:
          name: "Grafana"
        attrs:
          name: "Grafana"
          client_id: "grafana"
          client_secret: !Env "AUTHENTIK_GRAFANA_CLIENT_SECRET"
          client_type: confidential
          authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
          invalidation_flow: !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]
          redirect_uris:
            - url: "https://grafana.${domain}/login/generic_oauth"
              matching_mode: strict
          signing_key: !Find [authentik_crypto.certificatekeypair, [name, "authentik Self-signed Certificate"]]
          sub_mode: hashed_user_id
          include_claims_in_id_token: true
          property_mappings:
            - !Find [authentik_providers_oauth2.scopemapping, [scope_name, openid]]
            - !Find [authentik_providers_oauth2.scopemapping, [scope_name, email]]
            - !Find [authentik_providers_oauth2.scopemapping, [scope_name, profile]]

      - model: authentik_core.application
        state: present
        identifiers:
          slug: grafana
        attrs:
          name: "Grafana"
          slug: grafana
          provider: !KeyOf provider-grafana
          policy_engine_mode: any

      # ── Nextcloud ───────────────────────────────────────────────────────────
      - model: authentik_providers_oauth2.oauth2provider
        id: provider-nextcloud
        state: present
        identifiers:
          name: "Nextcloud"
        attrs:
          name: "Nextcloud"
          client_id: "nextcloud"
          client_secret: !Env "AUTHENTIK_NEXTCLOUD_CLIENT_SECRET"
          client_type: confidential
          authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
          invalidation_flow: !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]
          redirect_uris:
            - url: "https://cloud.${domain}/apps/user_oidc/code"
              matching_mode: strict
          signing_key: !Find [authentik_crypto.certificatekeypair, [name, "authentik Self-signed Certificate"]]
          sub_mode: hashed_user_id
          include_claims_in_id_token: true
          property_mappings:
            - !Find [authentik_providers_oauth2.scopemapping, [scope_name, openid]]
            - !Find [authentik_providers_oauth2.scopemapping, [scope_name, email]]
            - !Find [authentik_providers_oauth2.scopemapping, [scope_name, profile]]

      - model: authentik_core.application
        state: present
        identifiers:
          slug: nextcloud
        attrs:
          name: "Nextcloud"
          slug: nextcloud
          provider: !KeyOf provider-nextcloud
          policy_engine_mode: any

      # ── Immich ──────────────────────────────────────────────────────────────
      - model: authentik_providers_oauth2.oauth2provider
        id: provider-immich
        state: present
        identifiers:
          name: "Immich"
        attrs:
          name: "Immich"
          client_id: "immich"
          client_secret: !Env "AUTHENTIK_IMMICH_CLIENT_SECRET"
          client_type: confidential
          authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
          invalidation_flow: !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]
          redirect_uris:
            - url: "https://photos.${domain}/auth/login"
              matching_mode: strict
            - url: "app.immich:///oauth-callback"
              matching_mode: strict
          signing_key: !Find [authentik_crypto.certificatekeypair, [name, "authentik Self-signed Certificate"]]
          sub_mode: hashed_user_id
          include_claims_in_id_token: true
          property_mappings:
            - !Find [authentik_providers_oauth2.scopemapping, [scope_name, openid]]
            - !Find [authentik_providers_oauth2.scopemapping, [scope_name, email]]
            - !Find [authentik_providers_oauth2.scopemapping, [scope_name, profile]]

      - model: authentik_core.application
        state: present
        identifiers:
          slug: immich
        attrs:
          name: "Immich"
          slug: immich
          provider: !KeyOf provider-immich
          policy_engine_mode: any

      # ── Home Assistant ──────────────────────────────────────────────────────
      # Authentik side only — HA side requires manual UI setup:
      #   Settings → Devices & Services → Add Integration → search "Authentik"
      #   (or via HACS: https://github.com/jchonig/ha-authentik)
      #   client_id: home-assistant
      #   discovery URL: https://auth.${domain}/application/o/home-assistant/.well-known/openid-configuration
      - model: authentik_providers_oauth2.oauth2provider
        id: provider-home-assistant
        state: present
        identifiers:
          name: "Home Assistant"
        attrs:
          name: "Home Assistant"
          client_id: "home-assistant"
          client_secret: !Env "AUTHENTIK_HA_CLIENT_SECRET"
          client_type: confidential
          authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
          invalidation_flow: !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]
          redirect_uris:
            - url: "https://ha.${domain}/auth/external/callback"
              matching_mode: strict
          signing_key: !Find [authentik_crypto.certificatekeypair, [name, "authentik Self-signed Certificate"]]
          sub_mode: hashed_user_id
          include_claims_in_id_token: true
          property_mappings:
            - !Find [authentik_providers_oauth2.scopemapping, [scope_name, openid]]
            - !Find [authentik_providers_oauth2.scopemapping, [scope_name, email]]
            - !Find [authentik_providers_oauth2.scopemapping, [scope_name, profile]]

      - model: authentik_core.application
        state: present
        identifiers:
          slug: home-assistant
        attrs:
          name: "Home Assistant"
          slug: home-assistant
          provider: !KeyOf provider-home-assistant
          policy_engine_mode: any

      # ── Jellyfin ────────────────────────────────────────────────────────────
      # Authentik side only — Jellyfin side requires manual setup:
      #   Install the "SSO Authentication" plugin from the Jellyfin plugin catalogue.
      #   Configure it with:
      #     Provider name: authentik
      #     client_id: jellyfin
      #     Authorization URL: https://auth.${domain}/application/o/authorize/
      #     Token URL:         https://auth.${domain}/application/o/token/
      #     Userinfo URL:      https://auth.${domain}/application/o/userinfo/
      - model: authentik_providers_oauth2.oauth2provider
        id: provider-jellyfin
        state: present
        identifiers:
          name: "Jellyfin"
        attrs:
          name: "Jellyfin"
          client_id: "jellyfin"
          client_secret: !Env "AUTHENTIK_JELLYFIN_CLIENT_SECRET"
          client_type: confidential
          authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
          invalidation_flow: !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]
          redirect_uris:
            - url: "https://media.${domain}/sso/OID/redirect/authentik"
              matching_mode: strict
          signing_key: !Find [authentik_crypto.certificatekeypair, [name, "authentik Self-signed Certificate"]]
          sub_mode: hashed_user_id
          include_claims_in_id_token: true
          property_mappings:
            - !Find [authentik_providers_oauth2.scopemapping, [scope_name, openid]]
            - !Find [authentik_providers_oauth2.scopemapping, [scope_name, email]]
            - !Find [authentik_providers_oauth2.scopemapping, [scope_name, profile]]

      - model: authentik_core.application
        state: present
        identifiers:
          slug: jellyfin
        attrs:
          name: "Jellyfin"
          slug: jellyfin
          provider: !KeyOf provider-jellyfin
          policy_engine_mode: any
  '';

  blueprintsDir = pkgs.runCommand "authentik-blueprints" {} ''
    mkdir -p $out
    cp ${proxyBlueprint} $out/10-proxy-providers.yaml
    cp ${oidcBlueprint}  $out/20-oidc-providers.yaml
  '';
in
{
  # Mount blueprints into both containers.  The Nix store path is read-only
  # on the host, so :ro is both safe and accurate.
  virtualisation.oci-containers.containers."authentik-server".volumes = [
    "${blueprintsDir}:/blueprints/custom:ro"
  ];
  virtualisation.oci-containers.containers."authentik-worker".volumes = [
    "${blueprintsDir}:/blueprints/custom:ro"
  ];

  # Inject OIDC client secrets so the blueprint can read them via !Env.
  # These are appended to the existing environmentFiles list (which already
  # contains authentik-env from authentik.nix).
  virtualisation.oci-containers.containers."authentik-server".environmentFiles = [
    config.age.secrets.authentik-oidc-secrets.path
  ];
  virtualisation.oci-containers.containers."authentik-worker".environmentFiles = [
    config.age.secrets.authentik-oidc-secrets.path
  ];

  age.secrets.authentik-oidc-secrets = {
    file  = ../../../secrets/authentik-oidc-secrets.age;
    owner = "authentik";
  };
}
