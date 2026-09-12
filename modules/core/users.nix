# modules/core/users.nix
#
# Accounts shared by both hosts.
#
# Service accounts are not declared here: each service file declares its own
# under lanbat.services.<name>.account (see modules/wiring/accounts.nix).
# NFS between the hosts uses numeric IDs (AUTH_SYS), so those accounts only
# need to exist on the host that runs the service.
#
# ID ranges:
#   900–999  service accounts and shared groups (checked for clashes)
#   1000+    human users
{ config, ... }:

{
  users.groups = {
    media.gid = 988; # bulk media read/write
    private.gid = 987; # restricted private shares; add users explicitly
  };

  # The admin logs in with the SSH key only and has no password, so sudo must
  # not ask for one. deploy-rs also relies on this.
  users.users.admin = {
    isNormalUser = true;
    uid = 1001;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [ config.lanbat.adminSshKey ];
  };

  security.sudo.wheelNeedsPassword = false;
}
