# modules/pi/launcher.nix
#
# TV/sofa launcher for the Pi.
#
# Approach
# --------
# - X11 with LightDM auto-login for the "media" user.
# - openbox as a minimal window manager.
# - On login, openbox runs the launcher (a Python/GTK3 full-screen menu).
# - The launcher presents two large buttons: Kodi and RetroArch.
# - Selecting one hides the launcher and runs the app.
# - When the app exits, the launcher reappears.
# - Controller input works via X11 joystick support.
#
# Why X11 and not Wayland?
#   Kodi and RetroArch both work on X11 with zero quirks on the Pi 5.
#   Wayland (via Cage/Sway) works too but adds surface-type negotiation
#   complexity.  X11 is simpler and more battle-tested for this use case.
{ config, pkgs, lib, ... }:

let
  launcherPkg = pkgs.callPackage ../../pkgs/launcher { };
in
{
  # ---------------------------------------------------------------------------
  # X server
  # ---------------------------------------------------------------------------
  services.xserver = {
    enable = true;

    # No desktop environment — openbox only.
    desktopManager.xterm.enable = false;
    windowManager.openbox.enable = true;

    # Autologin the media user straight into openbox.
    displayManager = {
      lightdm = {
        enable = true;
        # Hide the greeter entirely.
        autoLogin = {
          enable = true;
          user   = "media";
        };
        extraConfig = ''
          [LightDM]
          minimum-vt=1
        '';
      };
      defaultSession = "none+openbox";
    };
  };

  # ---------------------------------------------------------------------------
  # Openbox autostart — runs the launcher once X is up
  # ---------------------------------------------------------------------------
  # LightDM writes the session, which loads .config/openbox/autostart.
  # We write it system-wide via environment.etc.
  environment.etc."xdg/openbox/autostart".text = ''
    # Disable screen blanking and power management on the TV.
    xset s off
    xset -dpms
    xset s noblank

    # Launch the full-screen menu.
    ${launcherPkg}/bin/homelab-launcher &
  '';

  # ---------------------------------------------------------------------------
  # Packages available to the media user
  # ---------------------------------------------------------------------------
  environment.systemPackages = with pkgs; [
    kodi
    retroarch
    xorg.xset
    xorg.xrandr
    openbox
    launcherPkg

    # Controller support
    joystick
  ];

  # Load the joystick input module against the running kernel.
  boot.kernelModules = [ "joydev" ];

  # Kodi's home directory.
  systemd.tmpfiles.rules = [
    "d /var/lib/kodi      0755 media media -"
    "d /var/lib/retroarch 0755 media media -"
  ];

  # Allow the media user to call reboot/shutdown via polkit.
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if ((action.id == "org.freedesktop.login1.power-off" ||
           action.id == "org.freedesktop.login1.reboot") &&
           subject.user == "media") {
        return polkit.Result.YES;
      }
    });
  '';

  # Audio — PulseAudio for simplicity on a single-user TV box.
  hardware.pulseaudio.enable = true;
  hardware.pulseaudio.support32Bit = true;
}
