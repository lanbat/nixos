# tests/caddy-audit.nix
#
# caddy.auditLog and the user header, on the example profile's server:
#
#   - every forward-auth vhost removes the provider's user header from the
#     request before the check, so a client cannot name its own user;
#   - qBittorrent's vhost has no auth bypass, names the user on each access log
#     line, skips reads other than page loads, and keeps its log 90 days; a
#     forward-auth vhost without auditLog keeps the module's default log;
#   - Homepage's qBittorrent widget reads qBittorrent on loopback, with no
#     credentials;
#   - auditLog on a service without forward auth is an evaluation error;
#   - Caddy adapts the generated Caddyfile.
{
  lib,
  pkgs,
  inputs,
  self,
  agenix,
  disko,
  deploy-rs,
  nixpkgs,
  nixos-raspberrypi,
}:

let
  inputsWithSelf = inputs // {
    self = self // {
      lanbatPlugins = import ../plugins;
    };
  };

  exampleDeploy = import ../deployments/example/deploy.nix { inputs = inputsWithSelf; };

  lanbatLib = import ../lib {
    self = inputsWithSelf.self;
    inputs = inputsWithSelf;
    profiles = { };
    inherit
      nixpkgs
      nixos-raspberrypi
      agenix
      disko
      deploy-rs
      ;
  };

  # The example server's configuration, with extra modules merged last.
  serverWith =
    modules:
    let
      deploy = exampleDeploy // {
        hosts = exampleDeploy.hosts // {
          server = exampleDeploy.hosts.server // {
            modules = (exampleDeploy.hosts.server.modules or [ ]) ++ modules;
          };
        };
      };
    in
    (lanbatLib.mkProfile "example" deploy).configurations.example-server.config;

  failedAssertions = config: map (a: a.message) (lib.filter (a: !a.assertion) config.assertions);

  base = serverWith [ ];
  domain = base.lanbat.deployment.domain;
  vhostOf =
    name: base.services.caddy.virtualHosts."${base.lanbat.services.${name}.subdomain}.${domain}";

  torrent = vhostOf "qbittorrent";
  frigate = vhostOf "frigate";
  jackett = vhostOf "jackett";
  widget = base.lanbat.services.qbittorrent.dashboard.widget;

  auditOnApp = serverWith [ { lanbat.services.jellyfin.caddy.auditLog = true; } ];

  expect = name: ok: if ok then null else name;

  cases = [
    (expect "forward-auth vhosts remove a client's user header" (
      lib.all (lib.hasInfix "request_header -X-Authentik-Username") [
        torrent.extraConfig
        frigate.extraConfig
      ]
    ))

    (expect "qbittorrent: no part of the vhost bypasses Authentik" (
      !(lib.hasInfix "@auth_bypass" torrent.extraConfig)
    ))

    (expect "jackett: the management UI has no auth bypass and strips user headers" (
      !(lib.hasInfix "@auth_bypass" jackett.extraConfig)
      && lib.hasInfix "forward_auth" jackett.extraConfig
      && lib.hasInfix "request_header -X-Authentik-Username" jackett.extraConfig
    ))

    (expect "qbittorrent: the access log names the user and skips polling reads" (
      lib.hasInfix "log_append user {http.request.header.X-Authentik-Username}" torrent.extraConfig
      && lib.hasInfix "log_skip @audit_skip" torrent.extraConfig
      && lib.hasInfix "method GET HEAD" torrent.extraConfig
      && lib.hasInfix "not path /" torrent.extraConfig
    ))

    (expect "qbittorrent: the audit log is kept 90 days in the module's file" (
      lib.hasInfix "access-${base.lanbat.services.qbittorrent.subdomain}.${domain}.log" torrent.logFormat
      && lib.hasInfix "roll_keep_for 90d" torrent.logFormat
    ))

    (expect "a vhost without auditLog keeps the default log" (
      !(lib.hasInfix "log_append" frigate.extraConfig)
      && !(lib.hasInfix "roll_keep_for" frigate.logFormat)
    ))

    (expect "homepage: the qBittorrent widget reads loopback without credentials" (
      widget.url == "http://127.0.0.1:${toString base.lanbat.services.qbittorrent.port}"
      && !(widget ? password)
      && !(widget ? username)
    ))

    (expect "auditLog without forward auth is rejected" (
      lib.any (lib.hasInfix "jellyfin sets caddy.auditLog") (failedAssertions auditOnApp)
    ))

    (expect "the example profile's server has no failed assertion" (failedAssertions base == [ ]))
  ];

  failures = lib.filter (x: x != null) cases;
in
pkgs.runCommand "caddy-audit-check" { nativeBuildInputs = [ base.services.caddy.package ]; } ''
  if [ ${toString (lib.length failures)} -ne 0 ]; then
    echo "caddy audit checks failed:" >&2
    ${lib.concatStringsSep "\n" (map (msg: "echo \"  - ${msg}\" >&2") failures)}
    exit 1
  fi
  export HOME=$TMPDIR
  caddy adapt --adapter caddyfile --config ${base.services.caddy.configFile} > adapted.json
  touch $out
''
