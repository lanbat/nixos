# hosts/server/services/tang.nix
#
# Tang key server — the trust anchor for Pi Clevis LUKS unlock.
#
# Tang holds an asymmetric key pair.  The Pi's LUKS volume is bound to
# Tang's public key during initial setup.  At boot, the Pi sends a
# derivation request; Tang responds; Clevis decrypts the LUKS key material.
# No key ever leaves either side in plaintext.
#
# If the server is down when the Pi boots, the Pi cannot decrypt its drives.
# This is the desired failure behaviour.
#
# Tang key management
# -------------------
# Keys are stored in /var/lib/tang by default.  Back this directory up.
# Key rotation: `tangd-keygen /var/lib/tang` generates a new keypair.
# Old keys can be kept for a transition window then removed.
# After rotation, re-bind Pi volumes:
#   clevis luks regen -d /dev/sdX -s <slot>
{ pkgs, ... }:

{
  services.tang = {
    enable = true;
    # Tang listens on port 7500 by default in the NixOS module.
    # The server firewall in default.nix allows this port.
    listenStream = [ "0.0.0.0:7500" "[::]:7500" ];
  };

  # Ensure the key directory is backed up — see docs/backup.md.
  # Keys are auto-generated on first start if the directory is empty.
}
