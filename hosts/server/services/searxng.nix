# hosts/server/services/searxng.nix
#
# SearXNG — privacy-respecting metasearch engine.
#
# Why SearXNG instead of 4get?
#   4get is an excellent frontend but has no maintained Docker image and
#   requires PHP deployment.  SearXNG is:
#     - Actively maintained with official container images
#     - More feature-complete (more search engines, image/file search)
#     - Well-suited to homelab self-hosting
#     - Available at docker.io/searxng/searxng
#
# Auth: intentionally NONE.
#   This service is accessible to anyone on the LAN without authentication.
#   It is excluded from Authentik forward auth by design.
#   Caddy serves it at search.<domain> — no auth middleware.
#
# Always-on: yes.
#   No NFS dependency.  Lives entirely in a container with no persistent state.
{ config, pkgs, lib, ... }:

let domain = config.lanbat.domain; in

{
  virtualisation.oci-containers.containers."searxng" = {
    image = "docker.io/searxng/searxng:latest";

    environment = {
      INSTANCE_NAME = "Homelab Search";
      BASE_URL      = "https://search.${domain}/";
    };

    volumes = [
      "/var/lib/searxng:/etc/searxng"
    ];

    ports = [ "127.0.0.1:8888:8080" ];

    autoStart = true;
  };

  # Write a default SearXNG settings.yml if one does not exist.
  systemd.services."searxng-init-config" = {
    description = "Initialize SearXNG config";
    before      = [ "podman-searxng.service" ];
    wantedBy    = [ "podman-searxng.service" ];
    serviceConfig = {
      Type      = "oneshot";
      ExecStart = pkgs.writeShellScript "searxng-init" ''
        mkdir -p /var/lib/searxng
        if [ ! -f /var/lib/searxng/settings.yml ]; then
          cat > /var/lib/searxng/settings.yml << 'YAML'
general:
  instance_name: "Homelab Search"
  privacypolicy_url: false
  donation_url: false
  contact_url: false
  enable_metrics: false

server:
  port: 8080
  bind_address: "0.0.0.0"
  secret_key: "CHANGE_ME_SEARXNG_SECRET"
  limiter: false
  image_proxy: true
  http_protocol_version: "1.1"

ui:
  static_use_hash: true
  default_locale: "en"
  default_theme: "simple"

search:
  safe_search: 0
  autocomplete: ""
  default_lang: "auto"

engines:
  - name: google
    engine: google
    use_mobile_ui: false

  - name: bing
    engine: bing

  - name: ddg definitions
    engine: ddg_definitions
    categories: general

  - name: wikipedia
    engine: wikipedia
    language: en

  - name: openstreetmap
    engine: openstreetmap

  - name: github
    engine: github

outgoing:
  request_timeout: 6.0
  max_request_timeout: 15.0
  useragent_suffix: ""
  pool_connections: 100
  pool_maxsize: 10
YAML
          echo "SearXNG config initialized."
        fi
      '';
      RemainAfterExit = true;
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/searxng 0750 root root -"
  ];
}
