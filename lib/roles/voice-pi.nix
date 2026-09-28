# lib/roles/voice-pi.nix
#
# Voice Pi role: lightweight host for a Wyoming voice satellite endpoint.
# Everything it sets is shared with the storage Pi (lib/roles/pi-common.nix)
# or every role (lib/roles/common.nix). The
# satellite's port is opened and restricted by modules/wiring/policy.nix, from
# the edge Home Assistant declares.
args@{ lib, ... }:

{
  config = lib.mkMerge [
    (import ./common.nix args)
    (import ./pi-common.nix args)
  ];
}
