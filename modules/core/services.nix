# modules/core/services.nix
#
# The service interface. Every service file describes itself once under
# lanbat.services.<name>, and the wiring modules (modules/wiring/) turn those
# descriptions into Caddy vhosts, workload gating, NFS dependencies,
# on-demand activators, container accounts, agenix secrets and Homepage
# entries. modules/wiring/checks.nix rejects inconsistent descriptions at
# evaluation time.
#
# Importing a service file enables the service; there is no enable option.
#
# Example (services/jellyfin.nix):
#
#   lanbat.services.jellyfin = {
#     subdomain = "media";
#     port = 8096;
#     apiClients = true;
#     tier = "workload";
#     state = [ "jellyfin" ];
#     units = [ "jellyfin" ];
#     nfs.drives = [ "a" ];
#     account = { uid = 992; extraGroups = [ "media" ]; };
#     dashboard = { group = "Media"; name = "Jellyfin"; description = "Media server"; };
#   };
{ lib, ... }:

let
  inherit (lib) mkOption types;

  dirSubmodule = types.submodule (
    { config, ... }:
    {
      options = {
        user = mkOption {
          type = types.str;
          description = "Owner of the directory.";
        };
        group = mkOption {
          type = types.str;
          default = config.user;
          defaultText = lib.literalExpression "user";
          description = "Group of the directory.";
        };
        mode = mkOption {
          type = types.str;
          default = "0750";
          description = "Access mode of the directory.";
        };
      };
    }
  );

  secretSubmodule =
    defaultOwner:
    types.submodule {
      options = {
        owner = mkOption {
          type = types.str;
          default = defaultOwner;
          description = "User that can read the decrypted secret. Defaults to the service account, or the service name.";
        };
        group = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Group of the decrypted secret (agenix default when null).";
        };
        mode = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Mode of the decrypted secret (agenix default 0400 when null).";
        };
      };
    };

  serviceSubmodule = types.submodule (
    { name, config, ... }:
    {
      options = {
        # ── Web exposure (modules/wiring/caddy.nix) ───────────────────────────
        subdomain = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "media";
          description = "Serve the service at https://<subdomain>.<lanbat.domain> through Caddy.";
        };

        port = mkOption {
          type = types.nullOr types.port;
          default = null;
          description = "Local HTTP port of the service. Caddy proxies to it (or to the on-demand activator).";
        };

        extraPorts = mkOption {
          type = types.listOf types.port;
          default = [ ];
          description = "Other ports the service listens on. Only used to detect port clashes.";
        };

        auth = mkOption {
          type = types.enum [
            "app"
            "forward-auth"
            "none"
          ];
          default = "app";
          description = ''
            Who authenticates users of the web UI:
            - app: the service itself (native OIDC or its own accounts)
            - forward-auth: Caddy checks the Authentik session first
            - none: open to the LAN on purpose
          '';
        };

        apiClients = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Whether non-browser clients (mobile or desktop apps) call the service
            directly. With forward-auth, Caddy exempts /auth/token* and /api/*
            so clients can authenticate with the app while the browser UI stays
            behind Authentik.
          '';
        };

        caddy = {
          extraConfig = mkOption {
            type = types.lines;
            default = "";
            description = "Extra Caddyfile directives for the vhost, placed before the generated reverse_proxy.";
          };
          proxyOptions = mkOption {
            type = types.lines;
            default = "";
            description = "Directives inside the generated reverse_proxy block.";
          };
          authBypassPaths = mkOption {
            type = types.listOf types.str;
            default = [ ];
            example = [
              "/info"
              "/ws"
            ];
            description = ''
              URL paths that bypass Authentik forward-auth and reach the service
              directly. Used when the app must authenticate or discover itself
              (Music Assistant probes /info and /ws before its own login screen).
            '';
          };
        };

        # ── Storage tier (modules/wiring/workload-gate.nix) ───────────────────
        tier = mkOption {
          type = types.enum [
            "always-on"
            "workload"
          ];
          default = "always-on";
          description = ''
            always-on: starts at boot, state on the unencrypted host root.
            workload: starts only after unlock-workload, state on the workload LUKS layer.
          '';
        };

        state = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "jellyfin" ];
          description = "Directories under /var/lib that live on the workload layer (workload tier only).";
        };

        workloadDirs = mkOption {
          type = types.attrsOf dirSubmodule;
          default = { };
          example = {
            "immich/thumbs".user = "immich";
          };
          description = "Directories under /mnt/workload to create with this ownership when the layer is unlocked.";
        };

        units = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "podman-immich-server" ];
          description = "systemd services (without .service) that make up the service.";
        };

        # ── Pi storage (modules/wiring/nfs.nix) ───────────────────────────────
        nfs = {
          storageHost = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              Host key of the storage-pi that exports the drives. Defaults to
              deployment.primaryStorage when null.
            '';
          };
          drives = mkOption {
            type = types.listOf (
              types.enum [
                "a"
                "b"
              ]
            );
            default = [ ];
            description = "Pi storage drives the service reads or writes (/srv/storage/<drive>).";
          };
          units = mkOption {
            type = types.listOf types.str;
            default = config.units;
            defaultText = lib.literalExpression "units";
            description = "Units that stop when a drive disappears.";
          };
        };

        # ── On-demand activation (modules/wiring/on-demand.nix) ───────────────
        onDemand = mkOption {
          type = types.nullOr (
            types.submodule {
              options = {
                activatorPort = mkOption {
                  type = types.port;
                  description = "Port of the activator that Caddy proxies to.";
                };
                unit = mkOption {
                  type = types.str;
                  default = "${lib.head config.units}.service";
                  defaultText = lib.literalExpression ''"''${head units}.service"'';
                  description = "Unit the activator starts and the idle timer stops.";
                };
                idleMinutes = mkOption {
                  type = types.ints.positive;
                  default = 30;
                  description = "Stop the service after this long without requests.";
                };
              };
            }
          );
          default = null;
          description = "Start the service on the first request and stop it when idle.";
        };

        # ── Service account (modules/wiring/accounts.nix) ─────────────────────
        account = mkOption {
          type = types.nullOr (
            types.submodule {
              options = {
                name = mkOption {
                  type = types.str;
                  default = name;
                  defaultText = lib.literalExpression "<service name>";
                  description = "User and group name.";
                };
                uid = mkOption {
                  type = types.ints.between 900 999;
                  description = "UID and GID. Must be unique; checked at evaluation.";
                };
                container = mkOption {
                  type = types.bool;
                  default = false;
                  description = "Set up rootless Podman: linger, a home directory and sub-UID/GID ranges.";
                };
                extraGroups = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                  description = "Supplementary groups.";
                };
                extraSubGidRanges = mkOption {
                  type = types.listOf (types.attrsOf types.int);
                  default = [ ];
                  example = [
                    {
                      startGid = 303;
                      count = 1;
                    }
                  ];
                  description = "Extra sub-GID ranges, e.g. host device groups to pass into containers.";
                };
              };
            }
          );
          default = null;
          description = "Dedicated user and group with a pinned UID/GID.";
        };

        # ── Secrets (modules/wiring/secrets.nix) ──────────────────────────────
        secrets = mkOption {
          type = types.attrsOf (
            secretSubmodule (if config.account != null then config.account.name else name)
          );
          default = { };
          example = {
            vaultwarden-env = { };
          };
          description = "agenix secrets read from secrets/<name>.age.";
        };

        # ── Dashboard (services/homepage.nix) ─────────────────────────────────
        dashboard = mkOption {
          type = types.nullOr (
            types.submodule {
              options = {
                group = mkOption {
                  type = types.str;
                  description = "Homepage group the entry appears in.";
                };
                name = mkOption {
                  type = types.str;
                  description = "Display name.";
                };
                description = mkOption {
                  type = types.str;
                  description = "One-line description.";
                };
                icon = mkOption {
                  type = types.str;
                  default = name;
                  defaultText = lib.literalExpression "<service name>";
                  description = "Homepage icon name.";
                };
                widget = mkOption {
                  type = types.nullOr (types.attrsOf types.anything);
                  default = null;
                  description = "Homepage widget settings. url defaults to the service URL.";
                };
              };
            }
          );
          default = null;
          description = "Show the service on the Homepage dashboard.";
        };
      };
    }
  );
in
{
  options.lanbat.services = mkOption {
    type = types.attrsOf serviceSubmodule;
    default = { };
    description = "Self-descriptions of the services on this host. See modules/core/services.nix.";
  };
}
