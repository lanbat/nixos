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

  # Human users (admin, …) are declared in human-users.nix.

  security.sudo.wheelNeedsPassword = false;
}
