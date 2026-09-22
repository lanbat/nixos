# modules/core/auth.nix
#
# The authentication-provider contract.
#
# A service that sets auth = "forward-auth" wants every request checked before
# it reaches the application. The reverse-proxy wiring performs that check, but
# what the check looks like belongs to whichever provider serves it: the
# endpoint it calls, the headers it copies, the callback path the login flow
# returns to.
#
# The contract lives here, in a module every host imports, so that
# modules/wiring/caddy.nix never names a provider. Before this split it read
# config.lanbat.services.authentik.port eagerly, which meant a host using
# forward auth without Authentik failed inside a let binding rather than being
# told what was missing — and it meant core could not be used with any other
# provider.
{
  lib,
  ...
}:

let
  inherit (lib) mkOption types;
in
{
  options.lanbat.authProvider = mkOption {
    type = types.nullOr (
      types.submodule {
        options = {
          service = mkOption {
            type = types.str;
            example = "authentik";
            description = ''
              Name of the service providing authentication. Used in messages,
              so that a deployment is told which service it is missing.
            '';
          };

          outpostProxy = mkOption {
            type = types.lines;
            default = "";
            description = ''
              Caddyfile directives placed first inside a protected route.

              A provider whose login flow returns to a callback path on the
              same hostname routes that path to itself here, so the callback
              reaches the provider rather than the application behind it.
            '';
          };

          forwardAuth = mkOption {
            type = types.lines;
            description = ''
              Caddyfile directives that check a request and hand the identity
              to the application, typically a forward_auth block naming the
              provider's endpoint and the headers to copy.
            '';
          };
        };
      }
    );
    default = null;
    description = ''
      How requests are authenticated on this host, or null when nothing
      provides authentication. A service with auth = "forward-auth" requires
      it; services with auth = "app" or "none" do not.
    '';
  };
}
