# services/searxng.nix
#
# SearXNG — privacy-respecting metasearch engine.
#
# Auth: intentionally NONE.
#   This service is accessible to anyone on the LAN without authentication.
#   It is excluded from Authentik forward auth by design.
#   Caddy serves it at search.<domain> — no auth middleware.
#
# Always-on: yes.
#   No NFS dependency.  Lives entirely in a container with no persistent state.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  domain = config.lanbat.domain;
in

{
  lanbat.services.searxng = {
    subdomain = "search";
    port = 8888;
    auth = "none";
    account = {
      uid = 960;
      container = true;
    };
    dashboard = {
      group = "Utilities";
      name = "SearXNG";
      description = "Metasearch engine";
    };
  };

  virtualisation.oci-containers.containers."searxng" = {
    image = "docker.io/searxng/searxng:latest";

    # --pull=newer: on each start, check the registry and pull if a newer
    # image is available — keeps engine parsers in sync with upstream sites.
    extraOptions = [ "--pull=newer" ];

    volumes = [
      "/var/lib/searxng:/etc/searxng"
    ];

    ports = [ "127.0.0.1:8888:8080" ];

    podman.user = "searxng";
    user = "0";
    autoStart = true;
  };

  # Write the SearXNG settings.yml on every boot so Nix is the source of truth.
  # The file is always overwritten — no manual edits inside /var/lib/searxng.
  systemd.services."searxng-init-config" = {
    description = "Initialize SearXNG config";
    before = [ "podman-searxng.service" ];
    wantedBy = [ "podman-searxng.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "searxng-init" ''
                mkdir -p /var/lib/searxng
                cat > /var/lib/searxng/settings.yml << 'YAML'
        # Merge with SearXNG upstream defaults so schema-required fields are always
        # present even when we don't set them explicitly.
        use_default_settings: true

        general:
          instance_name: "Homelab Search"
          enable_metrics: false

        server:
          secret_key: "CHANGE_ME_SEARXNG_SECRET"
          # base_url must match the public URL so that image-proxy thumbnail links
          # embedded in results point to the right host.
          base_url: "https://search.${domain}/"
          limiter: false
          image_proxy: true
          public_instance: false

        ui:
          static_use_hash: true
          default_locale: "en"
          default_theme: "simple"

        search:
          safe_search: 0
          autocomplete: "brave"
          default_lang: "auto"

        outgoing:
          request_timeout: 6.0
          max_request_timeout: 15.0
          pool_connections: 100
          pool_maxsize: 10

        engines:
          # bing is disabled upstream but works from this IP.
          - name: bing
            disabled: false
          # wikidata SPARQL queries can exceed the default 3 s engine timeout.
          - name: wikidata
            timeout: 15.0
        YAML
                chown -R searxng:searxng /var/lib/searxng
                # 0755: uwsgi workers run as the container's searxng user, not root.
                # Rootless podman maps the host searxng uid to container root, so 0750
                # would leave workers unable to read settings.yml.
                chmod 755 /var/lib/searxng
      '';
      RemainAfterExit = true;
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/searxng 0755 searxng searxng -"
  ];
}
