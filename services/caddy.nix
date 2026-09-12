# services/caddy.nix
#
# Caddy reverse proxy with an internal CA.
#
# Design
# ------
# - Every service is HTTPS-only through Caddy's built-in CA; backends run
#   plain HTTP on localhost.
# - Service vhosts are generated from lanbat.services.<name>.subdomain by
#   modules/wiring/caddy.nix. This file configures Caddy itself and the CA
#   landing page at ca.<domain>, where clients download the root certificate.
#
# DNS assumption: *.<domain> → the server's IPv4 (and optionally IPv6).
#
# CA cert location: /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
# A systemd service copies it to /var/lib/ca-landing/root.crt for the landing page.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  domain = config.lanbat.domain;

  # "home.example.com" → "home\.example\.com" for the regex below.
  domainRe = builtins.replaceStrings [ "." ] [ "\\." ] domain;
in
{
  lanbat.services.caddy = {
    subdomain = "ca";
    auth = "none";
    extraPorts = [
      80
      443
      9999 # on-demand TLS check
    ];
    caddy.extraConfig = ''
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

  services.caddy = {
    enable = true;
    package = pkgs.caddy;

    globalConfig = ''
      # Leaf certs rotate automatically (default 7-day lifetime).
      # The root CA uses Caddy's default lifetime (10 years).
      pki {
        ca local {
          name      "Lanbat Homelab CA"
          root_cn   "Lanbat Root CA"
        }
      }

      # Allow on-demand TLS issuance for *.${domain}.
      on_demand_tls {
        ask http://localhost:9999/on-demand-check
      }
    '';
  };

  # ---------------------------------------------------------------------------
  # On-demand TLS check endpoint: tells Caddy whether a name may get a cert.
  # ---------------------------------------------------------------------------
  systemd.services."caddy-od-check" = {
    description = "Caddy on-demand TLS domain check";
    after = [ "network.target" ];
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
                domain = q.get('domain', ['''])[0]
                code = 200 if ALLOWED.match(domain) else 403
                self.send_response(code)
                self.end_headers()
            def log_message(self, *a): pass
        http.server.HTTPServer(('127.0.0.1', 9999), H).serve_forever()
        "
      '';
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  # ---------------------------------------------------------------------------
  # Copy the CA cert to the landing page dir after Caddy starts
  # ---------------------------------------------------------------------------
  systemd.services."caddy-export-ca" = {
    description = "Export Caddy CA cert to landing page dir";
    after = [ "caddy.service" ];
    wantedBy = [ "caddy.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "export-ca" ''
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

  # CA landing page static content (pkgs/ca-landing-page).
  systemd.services."caddy-install-ca-landing" = {
    description = "Install CA landing page assets";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "install-ca-landing" ''
        cp -r ${pkgs.callPackage ../pkgs/ca-landing-page { }}/. /var/lib/ca-landing/
        chmod -R 644 /var/lib/ca-landing/*
        chmod 755    /var/lib/ca-landing
      '';
      RemainAfterExit = true;
    };
  };

  systemd.tmpfiles.rules = [ "d /var/lib/ca-landing 0755 root root -" ];

  # ---------------------------------------------------------------------------
  # Server-side CA trust
  # ---------------------------------------------------------------------------
  # security.pki.certificateFiles needs certs at build time, but Caddy's root CA
  # is generated at runtime. Keep a combined CA bundle at a fixed path so
  # programs on the server trust internal TLS endpoints.

  system.activationScripts.caddy-local-ca = lib.stringAfter [ "etc" ] ''
    mkdir -p /var/lib/caddy-local-ca
    cat ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt \
      > /var/lib/caddy-local-ca/ca-certificates.crt
    # Append the Caddy root CA if it already exists (every boot except the first).
    _ca="/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt"
    [ -f "$_ca" ] && cat "$_ca" >> /var/lib/caddy-local-ca/ca-certificates.crt
  '';

  # First-boot catch-up: the CA cert doesn't exist during activation on a
  # fresh install, so rebuild the bundle after Caddy has generated it.
  systemd.services.caddy-trust-local-ca = {
    description = "Append Caddy internal root CA to system CA bundle";
    after = [ "caddy.service" ];
    requires = [ "caddy.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      src=/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
      for i in $(seq 1 30); do
        [ -f "$src" ] && break
        sleep 2
      done
      if [ ! -f "$src" ]; then
        echo "Caddy root CA not found after 60s" >&2
        exit 1
      fi
      cat ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt "$src" \
        > /var/lib/caddy-local-ca/ca-certificates.crt
    '';
  };

  # security.pki sets NIX_SSL_CERT_FILE with mkDefault, so normal priority wins.
  environment.variables = {
    NIX_SSL_CERT_FILE = "/var/lib/caddy-local-ca/ca-certificates.crt";
    SSL_CERT_FILE = "/var/lib/caddy-local-ca/ca-certificates.crt";
  };

  networking.firewall.allowedTCPPorts = [
    80
    443
  ];
}
