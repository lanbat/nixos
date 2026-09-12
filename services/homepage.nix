# services/homepage.nix
#
# Homepage — service dashboard and LAN landing page at home.<domain>.
# No authentication: it's the entry point.
#
# The dashboard entries are generated from lanbat.services.<name>.dashboard,
# grouped by dashboard.group and sorted by name. Config files are built with
# Nix and mounted read-only, so they update on every deploy.
#
# Networking
# ----------
# Homepage uses host networking so widget requests can reach Caddy on
# 127.0.0.1:443. Caddy's internal CA root cert is mounted into the container
# and trusted via NODE_EXTRA_CA_CERTS. Caddy generates the cert on the first
# TLS request; if Homepage starts earlier, widgets error until it restarts.
#
# Widget coverage
# ---------------
# Services behind Authentik forward auth are links only: their APIs aren't
# reachable without a session cookie.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  domain = config.lanbat.domain;
  yaml = pkgs.formats.yaml { };

  # Group order on the page, with icons. Groups not listed here come last.
  groupIcons = [
    {
      name = "Identity & Auth";
      icon = "mdi-shield-account";
    }
    {
      name = "Media";
      icon = "mdi-television-play";
    }
    {
      name = "Files & Sync";
      icon = "mdi-folder-sync";
    }
    {
      name = "Downloads";
      icon = "mdi-download";
    }
    {
      name = "Automation";
      icon = "mdi-home-automation";
    }
    {
      name = "Surveillance";
      icon = "mdi-cctv";
    }
    {
      name = "Monitoring";
      icon = "mdi-chart-line";
    }
    {
      name = "Utilities";
      icon = "mdi-tools";
    }
  ];

  onDashboard = lib.attrValues (
    lib.filterAttrs (_: svc: svc.dashboard != null) config.lanbat.services
  );
  url = svc: "https://${svc.subdomain}.${domain}";

  entry = svc: {
    ${svc.dashboard.name} = {
      href = url svc;
      inherit (svc.dashboard) description icon;
    }
    // lib.optionalAttrs (svc.dashboard.widget != null) {
      widget = {
        url = url svc;
      }
      // svc.dashboard.widget;
    };
  };

  knownGroups = map (g: g.name) groupIcons;
  groups =
    knownGroups
    ++ lib.sort lib.lessThan (
      lib.subtractLists knownGroups (lib.unique (map (svc: svc.dashboard.group) onDashboard))
    );
  inGroup =
    group:
    lib.sort (a: b: a.dashboard.name < b.dashboard.name) (
      lib.filter (svc: svc.dashboard.group == group) onDashboard
    );

  servicesYaml = yaml.generate "homepage-services.yaml" (
    map (group: { ${group} = map entry (inGroup group); }) (
      lib.filter (group: inGroup group != [ ]) groups
    )
  );

  # Written as text: YAML generated from an attrset would sort the layout
  # keys, and Homepage orders groups by them.
  settingsYaml = pkgs.writeText "homepage-settings.yaml" ''
    title: Homelab
    theme: dark
    color: slate
    headerStyle: boxed
    layout:
    ${lib.concatMapStrings (g: ''
      ${"  "}${g.name}:
          icon: ${g.icon}
    '') groupIcons}
  '';

  widgetsYaml = pkgs.writeText "homepage-widgets.yaml" ''
    - resources:
        cpu: true
        memory: true
        disk: /
    - datetime:
        text_size: l
        format:
          dateStyle: long
          timeStyle: short
  '';
in
{
  lanbat.services.homepage = {
    subdomain = "home";
    port = 3000;
    auth = "none";
    account = {
      uid = 961;
      container = true;
    };
  };

  virtualisation.oci-containers.containers."homepage" = {
    image = "ghcr.io/gethomepage/homepage:latest";

    volumes = [
      "${servicesYaml}:/app/config/services.yaml:ro"
      "${settingsYaml}:/app/config/settings.yaml:ro"
      "${widgetsYaml}:/app/config/widgets.yaml:ro"
      # Caddy's internal CA root cert, for widget TLS verification. The
      # ExecStartPre below makes it reachable for the rootless homepage user.
      "/var/lib/caddy/.local/share/caddy/pki/authorities/local:/caddy-ca:ro"
    ];

    extraOptions = [ "--network=host" ];

    environment = {
      HOMEPAGE_ALLOWED_HOSTS = "home.${domain},localhost";
      NODE_EXTRA_CA_CERTS = "/caddy-ca/root.crt";
    };

    podman.user = "homepage";
    user = "0";
    autoStart = true;
  };

  # Start after Caddy so the CA cert is more likely to exist.
  systemd.services."podman-homepage" = {
    after = [ "caddy.service" ];
    wants = [ "caddy.service" ];
    serviceConfig.ExecStartPre = [
      "+${pkgs.writeShellScript "homepage-fix-ca-perms" ''
        set -euo pipefail
        # Rootless Podman must be able to traverse every parent directory of the
        # bind-mount source. Caddy's state dir is 0700, so grant o+x down to the
        # cert dir. The cert itself may not exist yet on first boot.
        CERT_DIR=/var/lib/caddy/.local/share/caddy/pki/authorities/local
        if [ -d "$CERT_DIR" ]; then
          chmod o+x /var/lib/caddy
          chmod o+x /var/lib/caddy/.local
          chmod o+x /var/lib/caddy/.local/share
          chmod o+x /var/lib/caddy/.local/share/caddy
          chmod o+x /var/lib/caddy/.local/share/caddy/pki
          chmod o+x /var/lib/caddy/.local/share/caddy/pki/authorities
          chmod o+x "$CERT_DIR"
          [ -f "$CERT_DIR/root.crt" ] && chmod o+r "$CERT_DIR/root.crt"
        fi
      ''}"
    ];
  };
}
