# hosts/server/services/caddy.nix
#
# Caddy reverse proxy with internal CA.
#
# Design
# ------
# - All services are HTTPS-only internally via Caddy's built-in CA.
# - TLS terminates at Caddy; backends run plain HTTP on localhost.
# - IPv6 is enabled on Caddy's listening sockets; backends are IPv4 only.
# - The internal CA root cert is served at ca.<domain> for easy import.
#
# DNS assumption: *.<domain> → server's IPv4 (and optionally IPv6).
# Router / DNS is managed separately and is out of scope.
#
# CA cert location: /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
# This is exported via a systemd service to /var/lib/ca-landing/root.crt
# so the ca-landing vhost can serve it.
{ config, pkgs, lib, ... }:

let
  domain = config.lanbat.domain;  # set in modules/common/settings.nix

  # Escape dots for use inside Python/POSIX regex patterns.
  # "home.example.com" → "home\.example\.com"
  domainRe = builtins.replaceStrings ["."] ["\\."] domain;

  # All virtual hosts share this base TLS config.
  tls = ''
    tls internal {
      on_demand
    }
  '';

  # Authentik forward auth snippet — reuse in every protected vhost.
  # This tells Caddy to verify the session cookie with Authentik before
  # forwarding the request.
  authentikFwdAuth = ''
    forward_auth localhost:9000 {
      uri /outpost.goauthentik.io/auth/caddy
      copy_headers X-Authentik-Username X-Authentik-Groups X-Authentik-Email \
                   X-Authentik-Name X-Authentik-Uid X-Authentik-Jwt \
                   X-Authentik-Meta-Jwks X-Authentik-Meta-Outpost \
                   X-Authentik-Meta-Provider X-Authentik-Meta-App \
                   X-Authentik-Meta-Version
    }
  '';
in
{
  services.caddy = {
    enable = true;
    package = pkgs.caddy;

    # Global block — configure the internal CA.
    globalConfig = ''
      # Internal CA root certificate is stored under Caddy's data dir.
      # Leaf certs rotate automatically (default 7-day lifetime).
      # Root CA has a 10-year lifetime by default.
      pki {
        ca local {
          name      "Lanbat Homelab CA"
          root_cn   "Lanbat Root CA"
          # Increase root validity to reduce how often clients need to re-trust.
          # Leaf certs still rotate every 7 days automatically.
        }
      }

      # Allow on-demand TLS issuance for *.${domain}.
      on_demand_tls {
        ask http://localhost:9999/on-demand-check
      }
    '';

    # ---------------------------------------------------------------------------
    # Virtual hosts
    # ---------------------------------------------------------------------------
    virtualHosts = {

      # ------------------------------------------------------------------
      # CA cert landing page — no auth, available to anyone on LAN.
      # ------------------------------------------------------------------
      "ca.${domain}" = {
        extraConfig = ''
          ${tls}
          root * /var/lib/ca-landing
          file_server

          # Serve the live CA cert from Caddy's data dir.
          handle /root.crt {
            header Content-Type "application/x-pem-file"
            header Content-Disposition "attachment; filename=lanbat-ca.crt"
            file_server {
              root /var/lib/caddy/.local/share/caddy/pki/authorities/local
              index root.crt
            }
          }
        '';
      };

      # ------------------------------------------------------------------
      # Homepage dashboard — no auth (Authentik manages session for other
      # services; homepage is the LAN landing page).
      # ------------------------------------------------------------------
      "home.${domain}" = {
        extraConfig = ''
          ${tls}
          reverse_proxy localhost:3000
        '';
      };

      # ------------------------------------------------------------------
      # Authentik IdP — must be accessible without auth check.
      # ------------------------------------------------------------------
      "auth.${domain}" = {
        extraConfig = ''
          ${tls}
          reverse_proxy localhost:9000
        '';
      };

      # ------------------------------------------------------------------
      # Nextcloud
      # ------------------------------------------------------------------
      "cloud.${domain}" = {
        extraConfig = ''
          ${tls}

          # Nextcloud requires some URL rewrites.
          redir /.well-known/carddav /remote.php/dav 301
          redir /.well-known/caldav  /remote.php/dav 301

          # Nextcloud handles its own OIDC / local auth.
          reverse_proxy localhost:8080
        '';
      };

      # ------------------------------------------------------------------
      # Immich
      # ------------------------------------------------------------------
      "photos.${domain}" = {
        extraConfig = ''
          ${tls}
          # Immich handles OIDC itself.
          reverse_proxy localhost:2283
        '';
      };

      # ------------------------------------------------------------------
      # Jellyfin — Jellyfin manages its own users; forward auth optional.
      # ------------------------------------------------------------------
      "media.${domain}" = {
        extraConfig = ''
          ${tls}
          reverse_proxy localhost:8096
        '';
      };

      # ------------------------------------------------------------------
      # Home Assistant
      # ------------------------------------------------------------------
      "ha.${domain}" = {
        extraConfig = ''
          ${tls}
          # Home Assistant handles its own auth + OIDC outpost.
          # Large websocket timeouts for HA's live streams.
          reverse_proxy localhost:8123 {
            transport http {
              keepalive 24h
            }
          }
        '';
      };

      # ------------------------------------------------------------------
      # Frigate NVR
      # ------------------------------------------------------------------
      "nvr.${domain}" = {
        extraConfig = ''
          ${tls}
          ${authentikFwdAuth}
          reverse_proxy localhost:5000
        '';
      };

      # ------------------------------------------------------------------
      # qBittorrent
      # ------------------------------------------------------------------
      "torrent.${domain}" = {
        extraConfig = ''
          ${tls}
          ${authentikFwdAuth}
          reverse_proxy localhost:8090
        '';
      };

      # ------------------------------------------------------------------
      # Bitmagnet (on-demand — activator proxy handles startup)
      # ------------------------------------------------------------------
      "bitmagnet.${domain}" = {
        extraConfig = ''
          ${tls}
          ${authentikFwdAuth}
          # Routes to the on-demand activator which starts Bitmagnet on
          # first request and proxies transparently once it is up.
          reverse_proxy localhost:3332
        '';
      };

      # ------------------------------------------------------------------
      # SearXNG — intentionally no auth, public on LAN.
      # ------------------------------------------------------------------
      "search.${domain}" = {
        extraConfig = ''
          ${tls}
          reverse_proxy localhost:8888
        '';
      };

      # ------------------------------------------------------------------
      # Grafana — metrics dashboards.
      # InfluxDB is not exposed here; Grafana connects to it on localhost.
      # ------------------------------------------------------------------
      "grafana.${domain}" = {
        extraConfig = ''
          ${tls}
          # Grafana handles OIDC itself via generic_oauth → Authentik.
          reverse_proxy localhost:3030
        '';
      };

      # ------------------------------------------------------------------
      # Vaultwarden — password manager.
      # No Authentik forward auth; Bitwarden clients need direct API access.
      # Admin panel is protected by the ADMIN_TOKEN env var.
      # ------------------------------------------------------------------
      "vault.${domain}" = {
        extraConfig = ''
          ${tls}

          # WebSocket endpoint (browser extension live sync).
          handle /notifications/hub {
            reverse_proxy localhost:3012
          }
          handle /notifications/hub/negotiate {
            reverse_proxy localhost:3012
          }

          # Everything else goes to the main Vaultwarden HTTP server.
          reverse_proxy localhost:8222
        '';
      };

      # ------------------------------------------------------------------
      # Snapcast — multi-room audio control UI.
      # Forward auth protects the web UI; port 1704/1705 are open directly
      # on the firewall for snapclient connections (see snapcast.nix).
      # ------------------------------------------------------------------
      "audio.${domain}" = {
        extraConfig = ''
          ${tls}
          ${authentikFwdAuth}
          reverse_proxy localhost:1780
        '';
      };

      # ------------------------------------------------------------------
      # Syncthing — file sync web UI.
      # Forward auth protects the web UI. Syncthing sync clients connect
      # directly on port 22000 (TCP/UDP) and never go through Caddy, so
      # Authentik forward auth does not interfere with them.
      # ------------------------------------------------------------------
      "sync.${domain}" = {
        extraConfig = ''
          ${tls}
          ${authentikFwdAuth}
          reverse_proxy localhost:8384
        '';
      };

      # ------------------------------------------------------------------
      # Samba / file access helper (optional web UI redirect)
      # Future: add a Filebrowser or similar here.
      # ------------------------------------------------------------------

    };
  };

  # ---------------------------------------------------------------------------
  # On-demand TLS check endpoint
  # A tiny helper that tells Caddy whether a domain is allowed for issuance.
  # ---------------------------------------------------------------------------
  systemd.services."caddy-od-check" = {
    description = "Caddy on-demand TLS domain check";
    after    = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = pkgs.writeShellScript "od-check" ''
        exec ${pkgs.python3}/bin/python3 -c "
import http.server, re, sys
ALLOWED = re.compile(r'^[a-z0-9-]+\.${domainRe}$')
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        from urllib.parse import urlparse, parse_qs
        q = parse_qs(urlparse(self.path).query)
        domain = q.get('domain', [''])[0]
        code = 200 if ALLOWED.match(domain) else 403
        self.send_response(code)
        self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', 9999), H).serve_forever()
"
      '';
      Restart    = "on-failure";
      RestartSec = "5s";
    };
  };

  # ---------------------------------------------------------------------------
  # Copy CA cert to landing dir after Caddy starts
  # ---------------------------------------------------------------------------
  systemd.services."caddy-export-ca" = {
    description = "Export Caddy CA cert to landing page dir";
    after    = [ "caddy.service" ];
    wantedBy = [ "caddy.service" ];
    # Wait until the cert actually exists.
    serviceConfig = {
      Type       = "oneshot";
      RemainAfterExit = true;
      ExecStart  = pkgs.writeShellScript "export-ca" ''
        for i in $(seq 1 30); do
          src="/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt"
          if [ -f "$src" ]; then
            cp "$src" /var/lib/ca-landing/root.crt
            chmod 644 /var/lib/ca-landing/root.crt
            echo "CA cert exported."
            exit 0
          fi
          sleep 2
        done
        echo "WARNING: CA cert not found after 60s"
        exit 1
      '';
    };
  };

  # CA landing page static content.
  # The HTML lives in pkgs/ca-landing-page.
  systemd.services."caddy-install-ca-landing" = {
    description = "Install CA landing page assets";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type      = "oneshot";
      ExecStart = pkgs.writeShellScript "install-ca-landing" ''
        cp -r ${pkgs.callPackage ../../pkgs/ca-landing-page { }}/. /var/lib/ca-landing/
        chmod -R 644 /var/lib/ca-landing/*
        chmod 755    /var/lib/ca-landing
      '';
      RemainAfterExit = true;
    };
  };

  # Open firewall for Caddy.
  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
