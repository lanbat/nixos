# modules/pi/tv.nix
#
# TV frontend on the Pi's HDMI output, when lanbat.piTvFrontend is set.
#
# Two sessions take turns on the screen. Each is a systemd service that runs
# as the "media" user on tty1, and each conflicts with the other, so starting
# one stops the other:
#   tv-kodi.service    Kodi, drawing directly to the display (GBM)
#   tv-games.service   ES-DE (EmulationStation) in the cage kiosk compositor;
#                      the emulators it starts run in the same session
#   tv-chiaki.service  chiaki-ng (PlayStation Remote Play) in cage; on exit,
#                      returns to Kodi. There is no finished Kodi addon for
#                      Remote Play — chiaki-ng is the community standard.
#
# Switching sessions: `tv-switch kodi|games|chiaki|toggle` starts one and
# remembers it in /var/lib/tv-session/current, so the Pi boots back into it.
# Quitting Kodi normally opens EmulationStation; quitting ES-DE or chiaki-ng
# returns to Kodi.
#   - In Kodi: Favourites → "Games (EmulationStation)" or "PlayStation Remote
#     Play"; F9 / Ctrl+G for games, F10 / Ctrl+P for Remote Play.
#   - In Kodi: Power → Exit also hands off to EmulationStation.
#   - In ES-DE: the "Kodi" system.
#   - chiaki-ng still needs a one-time PSN login and console registration.
#   - On any controller: hold the Guide button for 2 seconds, or Select and
#     Start for 3 (tv-hotkey.service; works even when an emulator hangs).
#
# Kodi plays directly from the Pi NVMe mounts (no Jellyfin plugin). Repository
# addons (jurialmunkey, marcelveldt) are installed at bootstrap for browsing
# legal skins and streaming plugins in Add-ons → Install from repository.
#   - In a game, Select + Start quits back to ES-DE, and holding Start opens
#     the RetroArch menu.
#
# ROMs use ES-DE's layout, one directory per system (snes, psx, mame, ...), with
# the other media on drive B: /mnt/storage-b/media/roms/<system>.
# Emulator BIOS files go in roms/bios.
#
# Controllers: wired Xbox pads use the kernel's xpad driver, Bluetooth Xbox
# pads use xpadneo (pair once with bluetoothctl), and USB arcade encoders are
# generic HID joysticks. RetroArch maps them with its autoconfig profiles.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  romDirectory = "/mnt/storage-b/media/roms";
  home = "/var/lib/kodi";
  kodiTvConfig = pkgs.callPackage ../../pkgs/kodi-tv-config { };
  kodiBootstrap = pkgs.callPackage ../../pkgs/kodi-bootstrap { };
  chiakiTvConfig = pkgs.callPackage ../../pkgs/chiaki-tv-config { };

  # Emulators that run well on a Raspberry Pi 5.
  cores = with pkgs.libretro; [
    fceumm # NES
    nestopia
    snes9x # SNES
    genesis-plus-gx # Master System, Game Gear, Genesis, Sega CD
    picodrive # 32X
    gambatte # Game Boy, Game Boy Color
    mgba # Game Boy Advance
    beetle-pce-fast # PC Engine
    beetle-ngp # Neo Geo Pocket
    beetle-wswan # WonderSwan
    beetle-lynx # Lynx
    stella # Atari 2600
    prosystem # Atari 7800
    pcsx-rearmed # PlayStation
    swanstation
    mupen64plus # Nintendo 64
    melonds # Nintendo DS
    flycast # Dreamcast
    fbneo # arcade
    mame # arcade, current MAME romsets
  ];

  retroarch = pkgs.retroarch-bare.wrapper {
    inherit cores;
    # Applied on every start, over the user's retroarch.cfg.
    settings = {
      input_joypad_driver = "udev";
      input_autodetect_enable = "true";
      joypad_autoconfig_dir = "${pkgs.retroarch-joypad-autoconfig}/share/libretro/autoconfig";
      input_quit_gamepad_combo = "4"; # Select + Start
      input_menu_toggle_gamepad_combo = "7"; # hold Start
      video_fullscreen = "true";
      system_directory = "${romDirectory}/bios";
    };
  };

  # ES-DE's launch commands name the cores with underscores
  # (genesis_plus_gx_libretro.so), nixpkgs with hyphens.
  esdeCoreNames = pkgs.runCommand "es-de-core-names" { } (
    ''
      mkdir -p $out/lib/retroarch/cores
    ''
    + lib.concatMapStrings (
      core:
      lib.optionalString (lib.hasInfix "-" core.core) ''
        ln -s ${core}${core.libretroCore}/${core.core}_libretro.so \
          $out/lib/retroarch/cores/${lib.replaceStrings [ "-" ] [ "_" ] core.core}_libretro.so
      ''
    ) cores
  );

  es-de = pkgs.callPackage ../../pkgs/es-de { };

  # ES-DE uses the first emulator listed for a system. Where its default isn't
  # installed or runs poorly on a Pi, list this one first.
  preferredEmulators = {
    nes = "FCEUmm";
    pcengine = "Beetle PCE FAST";
    psx = "PCSX ReARMed";
    psp = "PPSSPP (Standalone)";
    nds = "melonDS";
  };

  switchToKodi = pkgs.writeTextDir "Kodi.sh" ''
    exec /run/current-system/sw/bin/tv-switch kodi
  '';

  esdeSystems =
    pkgs.runCommand "es_systems.xml"
      {
        nativeBuildInputs = [ pkgs.python3 ];
        preferences = builtins.toJSON preferredEmulators;
        passAsFile = [ "preferences" ];
      }
      ''
        python3 ${../../pkgs/tv-session/es-de-systems.py} \
          ${es-de.systems} "$preferencesPath" ${switchToKodi} $out
      '';

  # Seeded once: ES-DE rewrites its settings file.
  esdeSettings = pkgs.writeText "es_settings.xml" ''
    <?xml version="1.0"?>
    <string name="ROMDirectory" value="${romDirectory}" />
  '';

  kodi = pkgs.kodi-gbm.withPackages (
    addons: with addons; [
      joystick
      upnext
      vfs-rar
      youtube
      jurialmunkey
    ]
  );

  # Seeded once: Kodi rewrites its favourites.
  kodiFavourites = pkgs.writeText "favourites.xml" ''
    <favourites>
      <favourite name="Games (EmulationStation)">System.Exec(&quot;/run/current-system/sw/bin/tv-switch games&quot;)</favourite>
      <favourite name="PlayStation Remote Play">System.Exec(&quot;/run/current-system/sw/bin/tv-switch chiaki&quot;)</favourite>
    </favourites>
  '';

  tv-run-kodi = pkgs.writeShellApplication {
    name = "tv-run-kodi";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
      pkgs.sqlite
    ];
    text = builtins.readFile ../../pkgs/tv-session/tv-run-kodi.sh;
  };

  tv-run-games = pkgs.writeShellApplication {
    name = "tv-run-games";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
      pkgs.cage
      es-de
    ];
    text = builtins.readFile ../../pkgs/tv-session/tv-run-games.sh;
  };

  tv-run-chiaki = pkgs.writeShellApplication {
    name = "tv-run-chiaki";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
      pkgs.cage
      pkgs.chiaki-ng
    ];
    text = builtins.readFile ../../pkgs/tv-session/tv-run-chiaki.sh;
  };

  tv-switch = pkgs.writeShellApplication {
    name = "tv-switch";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
    ];
    text = builtins.readFile ../../pkgs/tv-session/tv-switch.sh;
  };

  tv-hotkey = pkgs.writers.writePython3Bin "tv-hotkey" {
    libraries = [ pkgs.python3Packages.evdev ];
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ../../pkgs/tv-session/tv-hotkey.py);

  session =
    {
      extraAfter ? [ ],
      description,
      others,
      command,
      restart ? "on-failure",
    }:
    {
      inherit description;
      conflicts = map (name: "${name}.service") others;
      after =
        [
          "systemd-user-sessions.service"
          "systemd-logind.service"
          "sound.target"
        ]
        ++ extraAfter;
      # Emulators and tv-switch are looked up in the system profile.
      path = [ "/run/current-system/sw" ];
      startLimitBurst = 5;
      startLimitIntervalSec = 60;
      serviceConfig = {
        ExecStart = command;
        User = "media";
        # A logind session on tty1 gives the session the display and input
        # devices. Audio goes to the system-wide PipeWire (modules/pi/audio.nix).
        PAMName = "login";
        TTYPath = "/dev/tty1";
        TTYReset = true;
        TTYVHangup = true;
        TTYVTDisallocate = true;
        StandardInput = "tty-fail";
        StandardOutput = "journal";
        StandardError = "journal";
        UtmpIdentifier = "tty1";
        UtmpMode = "user";
        Restart = restart;
        RestartSec = "2s";
      };
    };
in
{
  config = lib.mkIf config.lanbat.piTvFrontend {
    users.users.media = {
      uid = 1000;
      isNormalUser = true;
      home = "/var/lib/kodi";
      group = "media";
      extraGroups = [
        "audio"
        "pipewire"
        "video"
        "input"
        "render"
        "private"
      ];
    };

    hardware.graphics.enable = true;
    hardware.bluetooth = {
      enable = true;
      powerOnBoot = true;
    };
    hardware.xpadneo.enable = true;
    boot.kernelModules = [ "joydev" ];

    environment.systemPackages = [
      kodi
      retroarch
      esdeCoreNames
      pkgs.ppsspp-sdl
      es-de
      tv-switch
    ];
    # ES-DE looks for the cores in /run/current-system/sw/lib/retroarch/cores.
    environment.pathsToLink = [ "/lib/retroarch" ];

    systemd.services = {
      # tty1 belongs to the TV sessions; consoles remain on tty2 and up.
      "getty@tty1".enable = false;
      "autovt@tty1".enable = false;

      tv-kodi = session {
        description = "Kodi on the TV";
        others = [
          "tv-games"
          "tv-chiaki"
        ];
        command = "${lib.getExe tv-run-kodi}";
        extraAfter = [
          "kodi-bootstrap.service"
          "storage-a-unlock.service"
          "storage-b-unlock.service"
        ];
      };
      tv-games = session {
        description = "EmulationStation on the TV";
        others = [
          "tv-kodi"
          "tv-chiaki"
        ];
        command = "${lib.getExe tv-run-games}";
        restart = "no";
      };
      tv-chiaki = session {
        description = "PlayStation Remote Play on the TV";
        others = [
          "tv-kodi"
          "tv-games"
        ];
        command = "${lib.getExe tv-run-chiaki}";
        restart = "no";
      };

      kodi-bootstrap = {
        description = "Prepare Kodi storage, repositories, and bundled addons";
        wantedBy = [ "multi-user.target" ];
        after = [
          "storage-a-unlock.service"
          "storage-b-unlock.service"
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "root";
        };
        path = [ kodiBootstrap ];
        script = ''
          install -d -m 0755 -o media -g media \
            ${home}/.kodi/userdata/addon_data/plugin.video.youtube
          install -m 0644 -o media -g media \
            ${kodiTvConfig}/addon-data/plugin.video.youtube/settings.xml \
            ${home}/.kodi/userdata/addon_data/plugin.video.youtube/settings.xml
          exec kodi-bootstrap
        '';
      };

      tv-session = {
        description = "Start the last TV session";
        wantedBy = [ "multi-user.target" ];
        after = [
          "systemd-user-sessions.service"
          "kodi-bootstrap.service"
        ];
        serviceConfig.Type = "oneshot";
        script = ''
          session=$(cat /var/lib/tv-session/current 2>/dev/null || echo kodi)
          case "$session" in
            kodi | games | chiaki) ;;
            *) session=kodi ;;
          esac
          systemctl start --no-block "tv-$session.service"
        '';
      };

      tv-hotkey = {
        description = "Controller shortcut that switches TV sessions";
        wantedBy = [ "multi-user.target" ];
        environment.TV_SWITCH = lib.getExe tv-switch;
        serviceConfig = {
          ExecStart = lib.getExe tv-hotkey;
          Restart = "always";
          RestartSec = "5s";
        };
      };
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/tv-session 0775 root media -"
      "d ${home} 0755 media media -"

      "d ${home}/ES-DE 0755 media media -"
      "d ${home}/ES-DE/custom_systems 0755 media media -"
      "L+ ${home}/ES-DE/custom_systems/es_systems.xml - - - - ${esdeSystems}"
      "d ${home}/ES-DE/settings 0755 media media -"
      "C ${home}/ES-DE/settings/es_settings.xml - - - - ${esdeSettings}"
      "z ${home}/ES-DE/settings/es_settings.xml 0644 media media -"

      "d ${home}/.kodi 0755 media media -"
      "d ${home}/.kodi/userdata 0755 media media -"
      "d ${home}/.kodi/userdata/keymaps 0755 media media -"
      "C ${home}/.kodi/userdata/advancedsettings.xml - - - - ${kodiTvConfig}/advancedsettings.xml"
      "C ${home}/.kodi/userdata/sources.xml - - - - ${kodiTvConfig}/sources.xml"
      "C ${home}/.kodi/userdata/guisettings.xml - - - - ${kodiTvConfig}/guisettings.xml"
      "L+ ${home}/.kodi/userdata/keymaps/tv.xml - - - - ${kodiTvConfig}/keymaps/tv.xml"
      "d ${home}/.kodi/userdata/addon_data 0755 media media -"
      "d ${home}/.kodi/userdata/addon_data/plugin.video.youtube 0755 media media -"
      "C ${home}/.kodi/userdata/addon_data/plugin.video.youtube/settings.xml - - - - ${kodiTvConfig}/addon-data/plugin.video.youtube/settings.xml"
      "C ${home}/.kodi/userdata/favourites.xml - - - - ${kodiFavourites}"
      "z ${home}/.kodi/userdata/favourites.xml 0644 media media -"

      "d ${home}/.config 0755 media media -"
      "d ${home}/.config/Chiaki 0755 media media -"
      "C ${home}/.config/Chiaki/Chiaki.conf - - - - ${chiakiTvConfig}/Chiaki.conf"
      "z ${home}/.config/Chiaki/Chiaki.conf 0644 media media -"
    ];

    # The media user may switch TV sessions, reboot and power off, and nothing
    # else.
    security.polkit.enable = true;
    security.polkit.extraConfig = ''
      polkit.addRule(function (action, subject) {
        if (subject.user != "media") {
          return polkit.Result.NOT_HANDLED;
        }
        if (action.id == "org.freedesktop.systemd1.manage-units") {
          var unit = action.lookup("unit");
          var verb = action.lookup("verb");
          if ((unit == "tv-kodi.service" || unit == "tv-games.service" ||
               unit == "tv-chiaki.service") &&
              (verb == "start" || verb == "restart")) {
            return polkit.Result.YES;
          }
        }
        if (action.id == "org.freedesktop.login1.power-off" ||
            action.id == "org.freedesktop.login1.reboot") {
          return polkit.Result.YES;
        }
        return polkit.Result.NOT_HANDLED;
      });
    '';
  };
}
