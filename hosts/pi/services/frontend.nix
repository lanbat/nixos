# hosts/pi/services/frontend.nix
#
# TV frontend service config — complements modules/pi/launcher.nix.
#
# This file handles:
#   - Hardware video acceleration (VC4/V3D for Pi 5)
#   - Controller/gamepad setup
#   - Kodi and RetroArch service config
#   - Auto-mount of Pi storage for media playback
#
# Media paths for Kodi
# --------------------
# Kodi reads media directly from the Pi's local mounts:
#   /mnt/storage-a/media/movies
#   /mnt/storage-a/media/tv
#   /mnt/storage-a/media/music
#
# Kodi should access storage-a locally — no NFS hop needed since it's
# sitting right next to the drives.
{ config, pkgs, lib, ... }:

{
  # ---------------------------------------------------------------------------
  # Video acceleration — Pi 5 uses V3D (not VC4 like Pi 4).
  # ---------------------------------------------------------------------------
  hardware.raspberry-pi."5".fkms-3d.enable = lib.mkDefault false;
  # V3D is the KMS driver for Pi 5; it should be enabled automatically by
  # the nixos-hardware module.  If Kodi has no acceleration, check:
  #   /sys/class/drm — should show card0 and render devices.

  hardware.opengl = {
    enable          = true;
    driSupport      = true;
    driSupport32Bit = false; # Pi is aarch64, no 32-bit needed
  };

  # ---------------------------------------------------------------------------
  # Audio
  # ---------------------------------------------------------------------------
  # PulseAudio for simplicity.  Kodi and RetroArch both work with PA.
  hardware.pulseaudio.enable = true;

  # HDMI audio — ensure the HDMI audio device is available.
  sound.enable = true;

  # ---------------------------------------------------------------------------
  # Gamepad / controller
  # ---------------------------------------------------------------------------
  hardware.joystick = {
    enable = true;
  };

  # Udev rules for common controllers (Xbox, PS4/5, 8BitDo).
  services.udev.packages = with pkgs; [
    # xboxdrv not needed on modern kernels; xpad is built-in.
  ];

  # ---------------------------------------------------------------------------
  # Kodi — Home Theater PC mode
  # ---------------------------------------------------------------------------
  # Kodi reads from local Pi storage and/or NFS-mounted server paths.
  # For TV use, local reads are faster; add server NFS sources in Kodi's
  # media library settings via the UI.

  # Allow the media user to use the video group for DRM access.
  users.users.media.extraGroups = lib.mkForce [ "audio" "video" "input" "render" "media" ];

  # Kodi data dir.
  systemd.tmpfiles.rules = [
    "d /var/lib/kodi/.kodi             0755 media media -"
    "d /var/lib/kodi/.kodi/userdata    0755 media media -"
    "d /var/lib/kodi/.kodi/addons      0755 media media -"
    "d /var/lib/retroarch              0755 media media -"
    "d /var/lib/retroarch/system       0755 media media -"
    "d /var/lib/retroarch/saves        0755 media media -"
    "d /var/lib/retroarch/states       0755 media media -"
  ];

  # Symlink Kodi home to a predictable place.
  environment.etc."skel/.kodi".source = "/var/lib/kodi/.kodi";

  # ---------------------------------------------------------------------------
  # Packages
  # ---------------------------------------------------------------------------
  environment.systemPackages = with pkgs; [
    kodi
    retroarch
    retroarch-assets
    # Common RetroArch cores.
    # Add cores you need here — they are large; pick only what you'll use.
    # libretro.snes9x
    # libretro.mupen64plus
    # libretro.mgba
    # libretro.nestopia
    # libretro.mame
  ];
}
