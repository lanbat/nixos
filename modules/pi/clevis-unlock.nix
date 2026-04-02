# modules/pi/clevis-unlock.nix
#
# Clevis + Tang automatic LUKS unlock for the Pi's two storage drives.
#
# How it works
# ------------
# - Tang runs on the main server (see hosts/server/services/tang.nix).
# - Clevis is bound to Tang's public key during initial setup (manual step,
#   documented in docs/deployment-checklist.md).
# - At boot, the Pi's initrd runs `clevis luks unlock` for each drive.
# - If the server (Tang) is unreachable, unlock fails and the drives stay
#   encrypted.  The system still boots; storage simply isn't available.
# - Manual fallback: `cryptsetup luksOpen /dev/sdX storage-X --key-file /...`
#   or interactive passphrase entry.
#
# Assumptions
# -----------
# - /dev/sda = Drive A (media / torrents / surveillance / photos)
# - /dev/sdb = Drive B (nextcloud / users / backups)
# - Tang server IP: TANG_SERVER_IP (set in the host config)
# - This module is imported by hosts/pi/default.nix
{ config, pkgs, lib, ... }:

{
  # Pull in Clevis + Tang client support.
  environment.systemPackages = with pkgs; [
    clevis
    tang        # provides jose, needed by clevis
    tpm2-tools  # in case TPM binding is added later
  ];

  # Clevis must run in the initrd to unlock before the system mounts storage.
  boot.initrd.systemd.enable = true;

  # The initrd needs network to reach Tang.
  # Adjust the interface name to match the Pi's ethernet adapter.
  boot.initrd.network = {
    enable = true;
    # Use DHCP — Pi's ethernet should have a lease before Tang is contacted.
    udhcpc.enable = true;
  };

  # LUKS devices are declared in hosts/pi/services/storage.nix.
  # This module just ensures Clevis tooling is available in the initrd.
  boot.initrd.extraUtilsCommands = ''
    copy_bin_and_libs ${pkgs.clevis}/bin/clevis
    copy_bin_and_libs ${pkgs.clevis}/bin/clevis-luks-unlock
    copy_bin_and_libs ${pkgs.curl}/bin/curl
    copy_bin_and_libs ${pkgs.jose}/bin/jose
  '';

  # systemd-cryptenroll / clevis decrypt service in initrd.
  # NixOS's boot.initrd.luks.devices supports a "fido2" / "tpm2" source but
  # not Clevis directly out of the box.  We wire in Clevis via a custom
  # initrd systemd service unit.
  boot.initrd.systemd.services."clevis-unlock-storage-a" = {
    description = "Clevis unlock storage-a (Drive A)";
    # Run after the network is up but before the LUKS devices are needed.
    after    = [ "network-online.target" "systemd-udevd.service" ];
    before   = [ "cryptsetup.target" ];
    wantedBy = [ "cryptsetup.target" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      # clevis luks unlock -d /dev/sdX -n mapper-name
      # On failure (Tang unreachable), just warn — the drive stays locked.
      ExecStart = pkgs.writeShellScript "clevis-unlock-a" ''
        set +e
        ${pkgs.clevis}/bin/clevis luks unlock -d /dev/disk/by-id/CHANGE_ME_DRIVE_A -n storage-a
        rc=$?
        if [ $rc -ne 0 ]; then
          echo "WARNING: clevis unlock failed for Drive A (Tang unreachable?). Drive stays locked."
        fi
        exit 0
      '';
    };
  };

  boot.initrd.systemd.services."clevis-unlock-storage-b" = {
    description = "Clevis unlock storage-b (Drive B)";
    after    = [ "network-online.target" "systemd-udevd.service" ];
    before   = [ "cryptsetup.target" ];
    wantedBy = [ "cryptsetup.target" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "clevis-unlock-b" ''
        set +e
        ${pkgs.clevis}/bin/clevis luks unlock -d /dev/disk/by-id/CHANGE_ME_DRIVE_B -n storage-b
        rc=$?
        if [ $rc -ne 0 ]; then
          echo "WARNING: clevis unlock failed for Drive B (Tang unreachable?). Drive stays locked."
        fi
        exit 0
      '';
    };
  };

  # Declare the LUKS volumes so NixOS knows about them.
  # The actual unlock is handled by the Clevis services above;
  # these entries tell the rest of the system the mapper names.
  # Set "keyFile = null" and "preLVM = false" to skip the normal cryptsetup.
  # (The drives are already unlocked by Clevis at this point.)
  environment.etc."crypttab".text = ''
    # These entries are informational; Clevis handles the unlock above.
    # Manual fallback: cryptsetup luksOpen /dev/sdX storage-a
    # storage-a /dev/disk/by-id/CHANGE_ME_DRIVE_A none noauto
    # storage-b /dev/disk/by-id/CHANGE_ME_DRIVE_B none noauto
  '';
}
