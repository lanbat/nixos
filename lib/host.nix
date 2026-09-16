# lib/host.nix
#
# Pure helpers for cross-host lookups in a deployment.
{ lib }:

let
  hostsWithRole =
    hosts: role:
    lib.filter (name: hosts.${name}.role == role) (lib.attrNames hosts);

  primaryHost =
    hosts: role:
    let
      matches = hostsWithRole hosts role;
    in
    if matches == [ ] then null else lib.head matches;

  hostIp = hosts: name: hosts.${name}.networking.ip;

  hostHostname = hosts: name: hosts.${name}.networking.hostname;

  hostInterface = hosts: name: hosts.${name}.networking.interface;

  voiceRoomForHost =
    voiceRooms: hostKey:
    lib.findFirst (room: voiceRooms.${room} == hostKey) null (lib.attrNames voiceRooms);

in
{
  inherit hostsWithRole primaryHost hostIp hostHostname hostInterface voiceRoomForHost;
}
