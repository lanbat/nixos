# modules/core/base.nix
#
# Settings that are identical across both machines: locale, timezone,
# Nix daemon options, basic packages, and a few quality-of-life tweaks.
{
  config,
  pkgs,
  lib,
  ...
}:

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
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      # Deduplicate store paths on builds.
      auto-optimise-store = true;
      # Collect garbage during builds when free space drops below min-free,
      # until max-free is available again.
      min-free = 2 * 1024 * 1024 * 1024;
      max-free = 10 * 1024 * 1024 * 1024;
      # Users the Nix daemon trusts, e.g. to accept store paths copied by deploy-rs.
      trusted-users = [
        "root"
        "@wheel"
      ];
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
