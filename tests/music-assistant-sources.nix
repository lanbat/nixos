# tests/music-assistant-sources.nix
#
# Music Assistant's audio sources (services/music-assistant.nix), by pure
# evaluation of the example profile and of variants of it whose server carries
# one more module, as a profile's hosts.<key>.modules would. Its own check, not
# part of service-settings: every variant is a whole NixOS system, and one more
# evaluation process per check keeps CI's peak memory at the largest check.
#
#   - Radio, podcasts and video channels (through media-feed-bridge) come from
#     the settings and reach the sources step and the bridge; a channel name
#     that cannot be part of a feed URL is rejected; BBC Sounds can be left out.
#   - Audiobookshelf's provider runs with that service, as one of its gated units.
#   - The bridge's yt-dlp is updated daily on the configured channels, unless
#     turned off.
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

  # What music-assistant-sources and the audiobookshelf link are told to set up.
  maSources =
    config:
    builtins.fromJSON (
      builtins.readFile config.systemd.services.music-assistant-sources.environment.MA_SOURCES_CONFIG
    );
  maBridge =
    config:
    builtins.fromJSON (
      builtins.readFile (
        lib.last (lib.splitString " " config.systemd.services.media-feed-bridge.serviceConfig.ExecStart)
      )
    );

  maSourcesSet = serverWith [
    {
      lanbat.services.music-assistant.settings = {
        podcastCountry = "bg";
        tuneinUsername = "alice";
        podcasts = [ "https://example.org/feed.xml" ];
        channels = {
          news.url = "https://www.youtube.com/@news/videos";
          pt.url = "https://peertube.example.org/c/pt/videos";
        };
        channelEpisodes = 20;
        stations = [
          {
            name = "BNR Horizont";
            country = "bg";
          }
          {
            name = "Direct";
            url = "https://stream.example.org/live.aac";
          }
        ];
      };
    }
  ];

  maBadChannel = serverWith [
    { lanbat.services.music-assistant.settings.channels."Bad Name".url = "https://example.org/c"; }
  ];

  maNoUpdate = serverWith [
    {
      lanbat.services.music-assistant.settings = {
        channels.news.url = "https://www.youtube.com/@news/videos";
        updateYtDlp = false;
      };
    }
  ];

  maNoBbc = serverWith [
    { lanbat.services.music-assistant.settings.bbcSounds = false; }
  ];

  expect = name: ok: if ok then null else name;

  cases = [
    (expect
      "music-assistant: by default it gets the radio and podcast providers, no bridge and no stations"
      (
        let
          sources = maSources base;
        in
        lib.attrNames sources.providers == [
          "bbc_sounds"
          "itunes_podcasts"
          "radiobrowser"
          "radioparadise"
        ]
        && sources.providers.itunes_podcasts.locale == "us"
        && sources.stations == [ ]
        && sources.podcasts == [ ]
        && sources.bridge.feeds == [ ]
        && !(base.systemd.services ? media-feed-bridge)
        && lib.all (p: lib.elem p base.services.music-assistant.providers) [
          "radiobrowser"
          "podcastfeed"
          "itunes_podcasts"
          "bbc_sounds"
          "audiobookshelf"
        ]
      )
    )

    (expect "music-assistant: the settings reach the sources step and the bridge" (
      let
        sources = maSources maSourcesSet;
        bridge = maBridge maSourcesSet;
        unit = maSourcesSet.systemd.services.music-assistant-sources;
      in
      sources.providers.itunes_podcasts.locale == "bg"
      && sources.providers.tunein.username == "alice"
      && sources.podcasts == [ "https://example.org/feed.xml" ]
      &&
        sources.stations == [
          {
            name = "BNR Horizont";
            country = "bg";
            url = null;
          }
          {
            name = "Direct";
            country = null;
            url = "https://stream.example.org/live.aac";
          }
        ]
      &&
        sources.bridge.feeds == [
          "news"
          "pt"
        ]
      && sources.bridge.prefix == "http://127.0.0.1:8101/feed/"
      && bridge.port == 8101
      && bridge.limit == 20
      && bridge.feeds.news == "https://www.youtube.com/@news/videos"
      && lib.elem "media-feed-bridge.service" unit.after
      && lib.elem "music-assistant-setup.service" unit.requires
      && failedAssertions maSourcesSet == [ ]
    ))

    (expect "music-assistant: a channel name that cannot be part of a feed URL is rejected" (
      lib.any (lib.hasInfix "Bad Name") (failedAssertions maBadChannel)
    ))

    (expect "music-assistant: yt-dlp is updated daily, on the configured channels, unless turned off" (
      let
        update = maSourcesSet.systemd.services.media-feed-bridge-update-yt-dlp;
        bridgeUnit = maSourcesSet.systemd.services.media-feed-bridge;
      in
      lib.hasInfix "media-feed-bridge-update-yt-dlp" update.serviceConfig.ExecStart
      && lib.hasSuffix ".json" update.serviceConfig.ExecStart
      && update.serviceConfig.Type == "oneshot"
      # Same dynamic user, so the same state directory.
      && update.serviceConfig.User == bridgeUnit.serviceConfig.User
      && update.serviceConfig.StateDirectory == bridgeUnit.serviceConfig.StateDirectory
      && maSourcesSet.systemd.timers.media-feed-bridge-update-yt-dlp.timerConfig.OnUnitInactiveSec == "1d"
      && !(maNoUpdate.systemd.services ? media-feed-bridge-update-yt-dlp)
      && !(maNoUpdate.systemd.timers ? media-feed-bridge-update-yt-dlp)
      && maNoUpdate.systemd.services ? media-feed-bridge
      && !(base.systemd.timers ? media-feed-bridge-update-yt-dlp)
    ))

    (expect "music-assistant: the BBC Sounds provider can be left out" (
      !(lib.elem "bbc_sounds" maNoBbc.services.music-assistant.providers)
      && !(maSources maNoBbc).providers ? bbc_sounds
    ))

    (expect "music-assistant: the Audiobookshelf link is one of Audiobookshelf's gated units" (
      lib.elem "music-assistant-audiobookshelf" base.lanbat.services.audiobookshelf.units
      && base.systemd.services.music-assistant-audiobookshelf.wantedBy == [ "workload-online.target" ]
      && lib.elem "audiobookshelf-bootstrap.service" base.systemd.services.music-assistant-audiobookshelf.after
      && (maSources base).audiobookshelf.url == "http://127.0.0.1:13378"
    ))
  ];

  failures = lib.filter (x: x != null) cases;
in
pkgs.runCommand "music-assistant-sources-check" { } ''
  if [ ${toString (lib.length failures)} -ne 0 ]; then
    echo "music assistant sources checks failed:" >&2
    ${lib.concatStringsSep "\n" (map (msg: "echo \"  - ${msg}\" >&2") failures)}
    exit 1
  fi
  touch $out
''
