# hosts/server/services/samba.nix
#
# Samba — SMB file server for Linux/Windows/macOS clients.
#
# Architecture
# ------------
# - Samba lives on the server only.
# - Shares are backed by NFS-mounted Pi storage (/srv/storage/b).
# - Users authenticate via Authentik LDAP outpost.
#
# Auth approach
# -------------
# Authentik exposes an LDAP outpost (port 3389) that speaks LDAPv3.
# Samba is configured with "passdb backend = ldapsam" pointing to the
# Authentik LDAP outpost.  User passwords are validated against Authentik.
#
# Caveats:
#   - Samba with ldapsam needs NT password hashes in LDAP.  Authentik
#     does NOT store NT hashes by default.
#   - Practical workaround: use "idmap" with winbind + Authentik LDAP
#     for user/group resolution, but keep password auth as local Samba
#     user DB that is manually synced.
#
# RECOMMENDED PRAGMATIC APPROACH:
#   Use local Samba users (smbpasswd) with the same usernames as Authentik.
#   Sync passwords manually when a user changes their Authentik password.
#   This is unsophisticated but reliable.  Full Kerberos/AD integration
#   is out of scope for a homelab.
#
# If you want better integration later, look at:
#   - Samba AD DC (heavyweight — not recommended here)
#   - sssd + Authentik LDAP (good for POSIX, not SMB passwords)
#
# NFS dependency: strong.
#   Shares are backed by /srv/storage/b.  Stop Samba when Pi is gone.
{ config, pkgs, lib, ... }:

{
  services.samba = {
    enable       = true;
    openFirewall = true;  # opens 137,138,139,445

    settings = {
      global = {
        workgroup            = "WORKGROUP";
        "server string"      = "Homelab Server";
        "netbios name"       = "server";
        security             = "user";
        "map to guest"       = "bad user";
        "log level"          = "1";
        "max log size"       = "10000";

        # Performance.
        "use sendfile"       = "yes";
        "aio read size"      = "16384";
        "aio write size"     = "16384";
        "socket options"     = "TCP_NODELAY IPTOS_THROUGHPUT SO_RCVBUF=131072 SO_SNDBUF=131072";

        # macOS compatibility.
        "vfs objects"        = "catia fruit streams_xattr";
        "fruit:metadata"     = "stream";
        "fruit:model"        = "MacSamba";
        "fruit:posix_rename" = "yes";
        "fruit:veto_appledouble" = "no";
        "fruit:wipe_intentionally_left_blank_rfork" = "yes";
        "fruit:delete_empty_adfiles" = "yes";

        # LDAP backend — Authentik LDAP outpost.
        # Uncomment and configure if using LDAP for user resolution.
        # "passdb backend" = "ldapsam:ldap://127.0.0.1:3389";
        # "ldap admin dn"  = "cn=admin,dc=s,dc=10ctr,dc=vg,dc=cd";
        # "ldap ssl"       = "no";
      };

      # ---- User home share ----
      homes = {
        comment           = "Home Directories";
        browseable        = "no";
        "read only"       = "no";
        "create mask"     = "0700";
        "directory mask"  = "0700";
        "valid users"     = "%S";
        path              = "/srv/storage/b/users/%S";
      };

      # ---- Shared media share (read-only for all users) ----
      media = {
        comment           = "Media";
        path              = "/srv/storage/a/media";
        browseable        = "yes";
        "read only"       = "yes";
        "guest ok"        = "no";
        "valid users"     = "@media";
        "create mask"     = "0664";
        "directory mask"  = "0775";
      };

      # ---- Downloads share ----
      downloads = {
        comment           = "Downloads";
        path              = "/srv/storage/a/downloads";
        browseable        = "yes";
        "read only"       = "no";
        "guest ok"        = "no";
        "valid users"     = "@media";
        "create mask"     = "0664";
        "directory mask"  = "0775";
        "force group"     = "media";
      };

      # ---- Private downloads (restricted to "private" group) ----
      # Not browseable — does not appear in network discovery.
      # Only users explicitly added to the "private" group can access it.
      # Add users: usermod -aG private <username> && smbpasswd -a <username>
      private-downloads = {
        comment          = "Private";
        path             = "/srv/storage/a/downloads/private";
        browseable       = "no";   # hidden from share listings
        "read only"      = "no";
        "guest ok"       = "no";
        "valid users"    = "@private";
        "create mask"    = "0600";
        "directory mask" = "0700";
        "force group"    = "private";
      };

      # ---- Shared space ----
      shared = {
        comment           = "Shared";
        path              = "/srv/storage/b/shared";
        browseable        = "yes";
        "read only"       = "no";
        "guest ok"        = "no";
        "valid users"     = "@media";
        "create mask"     = "0664";
        "directory mask"  = "0775";
        "force group"     = "media";
      };
    };
  };

  # Samba avahi announcement for macOS autodiscovery.
  services.avahi = {
    enable    = true;
    nssmdns4  = true;
    publish   = {
      enable         = true;
      userServices   = true;
    };
  };

  # ---------------------------------------------------------------------------
  # NFS dependency — stop Samba if Pi storage disappears.
  # ---------------------------------------------------------------------------
  lanbat.nfsDependentServices."samba-smbd" = [ "a" "b" ];

  systemd.services.samba-smbd = {
    serviceConfig = {
      Restart    = "on-failure";
      RestartSec = "15s";
    };
  };

  # Pre-create user home dirs on Pi storage (add users as needed).
  systemd.tmpfiles.rules = [
    "d /srv/storage/b/users                  0755 root  root    -"
    "d /srv/storage/b/users/admin            0700 admin admin   -"
    "d /srv/storage/b/shared                 0775 root  media   -"
    # Private downloads — mode 0770 so only owner+group can enter.
    "d /srv/storage/a/downloads/private      0770 admin private -"
  ];

  # Note: add Samba users manually after deploying:
  #   smbpasswd -a <username>
  # or via a provisioning script.  Passwords must match what users know.
  # See docs/operations.md.
}
