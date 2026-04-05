# modules/common/base.nix
#
# Settings that are identical across both machines: locale, timezone,
# Nix daemon options, basic packages, and a few quality-of-life tweaks.
{ config, pkgs, lib, ... }:

{
  # ---------------------------------------------------------------------------
  # Locale / time
  # ---------------------------------------------------------------------------
  time.timeZone = config.lanbat.timezone;
  i18n.defaultLocale = "en_US.UTF-8";

  # ---------------------------------------------------------------------------
  # Nix daemon
  # ---------------------------------------------------------------------------
  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      # Deduplicate store paths on builds.
      auto-optimise-store = true;
      # Trusted users who can submit substitutions or use --impure.
      trusted-users = [ "root" "@wheel" ];
    };

    # Garbage-collect weekly.
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };

# ---------------------------------------------------------------------------
  # Base packages available on both machines
  # ---------------------------------------------------------------------------
  environment.systemPackages = with pkgs; [
    # Diagnostics
    htop
    iotop
    ncdu
    lsof
    strace
    tcpdump
    nmap
    iproute2
    ethtool

    # File tools
    rsync
    git
    jq
    yq-go
    vim
    less
    tree
    file
    unzip
    zip
    gptfdisk
    parted

    # Crypto / security
    age
    openssl

    # Network
    curl
    wget
    dnsutils
    iputils

    # System
    smartmontools
    hdparm
    util-linux
    lvm2
    cryptsetup
  ];

  # ---------------------------------------------------------------------------
  # SSH hardening (openssh enabled per-host)
  # ---------------------------------------------------------------------------
  programs.ssh.startAgent = false;

  # ---------------------------------------------------------------------------
  # Basic audit trail
  # ---------------------------------------------------------------------------
  services.journald.extraConfig = ''
    SystemMaxUse=2G
    MaxRetentionSec=90day
  '';
}
