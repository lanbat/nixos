# lib/host.nix
#
# Pure helpers for cross-host lookups in a deployment.
{ lib }:

let
  hostsWithRole = hosts: role: lib.filter (name: hosts.${name}.role == role) (lib.attrNames hosts);

  primaryHost =
    hosts: role:
    let
      matches = hostsWithRole hosts role;
    in
    if matches == [ ] then null else lib.head matches;

  hostIp = hosts: name: hosts.${name}.networking.ip;

  hostHostname = hosts: name: hosts.${name}.networking.hostname;

  hostInterface = hosts: name: hosts.${name}.networking.interface;

  # A room's hosts: lanbat.deployment.voiceRooms takes one host key or a list.
  voiceRoomHosts = hosts: lib.toList hosts;

  voiceRoomForHost =
    voiceRooms: hostKey:
    lib.findFirst (room: lib.elem hostKey (lib.toList voiceRooms.${room})) null (
      lib.attrNames voiceRooms
    );

  # Whether a haLlm (lanbat.deployment.haLlm) is served from this host's own
  # loopback, that is by its llama-cpp service, rather than by an outside API.
  # Null (no LLM) is not local.
  haLlmIsLocal =
    haLlm:
    haLlm != null
    && builtins.match "https?://(127\\.0\\.0\\.1|localhost)([/:].*)?" haLlm.baseUrl != null;

in
{
  inherit
    haLlmIsLocal
    hostsWithRole
    primaryHost
    hostIp
    hostHostname
    hostInterface
    voiceRoomForHost
    voiceRoomHosts
    ;
}
