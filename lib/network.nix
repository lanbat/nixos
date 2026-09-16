# lib/network.nix
{ lib }:

let
  prefixLengthFromCidr =
    cidr:
    let
      parts = lib.splitString "/" cidr;
    in
    if lib.length parts != 2 then
      builtins.throw "lanbat: invalid CIDR '${cidr}' (expected e.g. 192.168.1.0/24)"
    else
      lib.toInt (lib.elemAt parts 1);
in
{
  prefixLengthFromCidr = prefixLengthFromCidr;
}
