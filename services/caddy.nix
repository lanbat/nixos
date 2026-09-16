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
# Root CA persistence
# -------------------
# The root certificate (public) lives in secrets/caddy-ca-root.crt (committed).
# The root private key is secrets/caddy-ca-root-key.age (agenix), decrypted to
# /run/agenix/caddy-ca-root-key for the caddy user. Caddy is configured via
# pki.ca.local.root { cert key } so a host-root reinstall does not mint a new
# root. Intermediates and leaf certs remain in /var/lib/caddy/ and rotate on
# Caddy's default schedule (7d / 12h).
{
  config,
  pkgs,
  lib,
  ...
}:

let
  domain = config.lanbat.deployment.domain;

  # "home.example.com" → "home\.example\.com" for the regex below.
  domainRe = builtins.replaceStrings [ "." ] [ "\\." ] domain;

  caRootCert = ../secrets/caddy-ca-root.crt;
  caRootCertPath = "/etc/caddy/ca-root.crt";
  caRootKeyPath = config.age.secrets.caddy-ca-root-key.path;
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

      # caddy-export-ca writes the certificate as root.crt; old links to
      # /root.crt redirect to the download name.
      redir /root.crt /lanbat-ca.crt permanent

      handle /lanbat-ca.crt {
        rewrite * /root.crt
        header Content-Type "application/x-pem-file"
        header Content-Disposition "attachment; filename=lanbat-ca.crt"
        file_server
      }
    '';
  };

  age.secrets.caddy-ca-root-key = {
    file = ../secrets/caddy-ca-root-key.age;
    owner = config.services.caddy.user;
    mode = "0400";
  };

  environment.etc."caddy/ca-root.crt" = {
    source = caRootCert;
    mode = "0644";
  };

  services.caddy = {
    enable = true;
    package = pkgs.caddy;

    globalConfig = ''
      # Leaf certs rotate automatically (default 12h lifetime for tls internal).
      # Intermediates rotate every 7d; the root is pinned via cert/key below.
      pki {
        ca local {
          name    "Lanbat Homelab CA"
          root_cn "Lanbat Root CA"
          root {
            cert ${caRootCertPath}
            key  ${caRootKeyPath}
          }
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
  # Copy the persisted CA cert to the landing page dir at boot
  # ---------------------------------------------------------------------------
  systemd.services."caddy-export-ca" = {
    description = "Export Caddy CA cert to landing page dir";
    after = [ "systemd-tmpfiles-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "export-ca" ''
        cp ${caRootCertPath} /var/lib/ca-landing/root.crt
        chmod 644 /var/lib/ca-landing/root.crt
        echo "CA cert exported."
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

  systemd.tmpfiles.rules = [
    "d /var/lib/ca-landing 0755 root root -"
    "d /var/lib/caddy-error-pages 0755 root root -"
  ];

  systemd.services."caddy-install-error-pages" = {
    description = "Install Caddy upstream error pages";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "install-caddy-error-pages" ''
        cp -r ${
          pkgs.callPackage ../pkgs/service-unavailable-page { inherit domain; }
        }/. /var/lib/caddy-error-pages/
        chmod -R 644 /var/lib/caddy-error-pages/*
        chmod 755 /var/lib/caddy-error-pages
      '';
    };
  };

  # ---------------------------------------------------------------------------
  # Server-side CA trust
  # ---------------------------------------------------------------------------
  # Append the persisted root CA to the system bundle so programs on the server
  # trust internal TLS endpoints without waiting for Caddy's data directory.

  system.activationScripts.caddy-local-ca = lib.stringAfter [ "etc" ] ''
    mkdir -p /var/lib/caddy-local-ca
    cat ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt ${caRootCertPath} \
      > /var/lib/caddy-local-ca/ca-certificates.crt
  '';

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
