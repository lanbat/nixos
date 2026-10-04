# lib/platforms.nix
#
# The platforms a host can run on, as a table, the way lib/roles.nix is the
# table of roles. A platform is the machine, a role is what it does: the Pi 3
# and the Pi 5 can both be voice-pi hosts, and a Pi 4 will be too.
#
# Everything specific to one board lives in its own hosts/<board>/ directory
# and has one entry here; nothing else in the code names a board.
#
#   <platform> = {
#     system = "aarch64-linux";          # what a host on it must set as `system`
#     hardware = ./hosts/<board>/hardware.nix;   # kernel, firmware, filesystems
#     # Built with nixos-raspberrypi's nixosSystem and pinned nixpkgs, whose
#     # kernel and firmware come from that project's binary cache, rather than
#     # with plain nixpkgs.
#     nixosRaspberrypi = true;
#   };
#
# A host without a `platform` is "generic": any other machine, whose role
# carries its own hardware (the server's is the role module named "hardware").
{ lib }:

let
  root = ../.;

  builtinPlatforms = {
    # Booted from the stock NixOS aarch64 SD image, with the mainline kernel.
    raspberry-pi-3 = {
      system = "aarch64-linux";
      hardware = root + "/hosts/pi3/hardware.nix";
      nixosRaspberrypi = false;
    };
    raspberry-pi-5 = {
      system = "aarch64-linux";
      hardware = root + "/hosts/pi5/hardware.nix";
      nixosRaspberrypi = true;
    };
  };

  # Names that were the platform before there was another board of its kind.
  aliases = {
    raspberry-pi = "raspberry-pi-5";
  };

  names = lib.attrNames builtinPlatforms;

  # The platform a deploy entry asks for: its name after aliases, or "generic".
  nameOf =
    host:
    let
      requested = host.platform or "generic";
    in
    aliases.${requested} or requested;

  known = name: name == "generic" || builtinPlatforms ? ${name};

  # The platform's table entry, or null for a generic machine. Throws on a name
  # that is not in the table; lib/validate-deploy.nix reports that, with the
  # profile, before anything gets here.
  resolve =
    host:
    let
      name = nameOf host;
    in
    if name == "generic" then
      null
    else
      builtinPlatforms.${name} or (builtins.throw (
        "unknown lanbat platform '${host.platform}'; known platforms: generic, "
        + lib.concatStringsSep ", " names
      ));

  # What is wrong with a deploy entry's platform, as messages; [ ] when it is
  # fine.
  problems =
    host:
    let
      name = nameOf host;
      platform = resolve host;
    in
    if !(known name) then
      [
        "unknown platform '${host.platform}'; known platforms: generic, ${lib.concatStringsSep ", " names}"
      ]
    else
      lib.optional (
        platform != null && (host.system or null) != platform.system
      ) "platform ${name} needs system = \"${platform.system}\"";
in
{
  inherit
    builtinPlatforms
    aliases
    resolve
    problems
    ;
}
