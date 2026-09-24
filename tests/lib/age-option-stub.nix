# tests/lib/age-option-stub.nix
#
# agenix's age.secrets option without agenix, for pure-eval tests that only
# inspect what a module declares. Each secret gets the path agenix would give
# it; nothing is decrypted.
{ lib, ... }:

{
  options.age.secrets = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          freeformType = lib.types.attrsOf lib.types.anything;
          options.path = lib.mkOption {
            type = lib.types.str;
            default = "/run/agenix/${name}";
          };
        }
      )
    );
    default = { };
  };
}
