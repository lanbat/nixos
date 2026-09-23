# modules/overlay/none.nix
#
# The overlay contract answered by not having one.
#
# Hosts reach each other by their LAN hostname and address, exactly as they did
# before the contract existed, so a profile that chooses this — or says nothing,
# since it is the default — behaves identically to one built without any of
# this machinery.
#
# It is not a stub. A fork that wants no overlay should get a real answer to
# "where is that host", not a null it has to special-case.
{
  config,
  lib,
  ...
}:

{
  lanbat.overlay = {
    provider = "none";
    interface = null;
    nameOf = hostKey: config.lanbat.hosts.${hostKey}.networking.hostname;
    addressOf = hostKey: config.lanbat.hosts.${hostKey}.networking.ip;
    onOverlay = _: false;
    unit = null;
  };
}
