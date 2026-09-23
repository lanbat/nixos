# modules/core/overlay.nix
#
# The overlay-network contract.
#
# Cross-host service traffic runs on whatever network the profile chooses. What
# that network is — nothing at all, a WireGuard mesh, a control plane — is a
# per-profile decision, so core declares the questions and an implementation
# answers them, the same shape as lanbat.authProvider and the database contract.
#
# Consumers resolve NAMES, never addresses. lib/endpoints.nix resolves during
# evaluation while a control plane assigns addresses at runtime, so a name is
# the only answer every implementation can give. Each provider installs the
# mapping its own way: networking.hosts entries for a mesh, as
# modules/wiring/nfs.nix:50-66 already does for storage hosts, or MagicDNS.
#
# A profile that says nothing gets "none", which resolves to the LAN addresses
# already in lanbat.hosts and changes nothing.
{
  lib,
  ...
}:

let
  inherit (lib) mkOption types;
in
{
  options.lanbat.overlay = {
    provider = mkOption {
      type = types.str;
      internal = true;
      readOnly = true;
      description = ''
        Name of the implementation answering this contract, echoed from
        deployment.overlay.provider so a module can report which one is in use.
      '';
    };

    interface = mkOption {
      type = types.nullOr types.str;
      internal = true;
      readOnly = true;
      description = ''
        Network interface the overlay runs on, for binding services to it and
        matching it in firewall rules. Null when there is no overlay.
      '';
    };

    nameOf = mkOption {
      type = types.functionTo types.str;
      internal = true;
      readOnly = true;
      description = ''
        The name a host is reached by, given its host key. Always answerable —
        this is what consumers resolve.
      '';
    };

    addressOf = mkOption {
      type = types.functionTo (types.nullOr types.str);
      internal = true;
      readOnly = true;
      description = ''
        The address a host is reached at, given its host key, or null when the
        provider cannot know it during evaluation. Prefer nameOf.
      '';
    };

    onOverlay = mkOption {
      type = types.functionTo types.bool;
      internal = true;
      readOnly = true;
      description = ''
        Whether a host takes part, given its host key. Not every host need join.
      '';
    };

    unit = mkOption {
      type = types.nullOr types.str;
      internal = true;
      readOnly = true;
      description = ''
        Unit that brings the overlay up, for cross-host services to order
        after. Null when there is nothing to wait for.
      '';
    };
  };
}
