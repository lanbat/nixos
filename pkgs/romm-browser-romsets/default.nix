# Builds zip copies of the arcade romsets for RomM's browser player
# (services/romm.nix). See build-romsets.py.
{
  fetchurl,
  writers,
}:

writers.writePython3Bin "romm-browser-romsets" {
  flakeIgnore = [ "E501" ];
} (builtins.readFile ./build-romsets.py)
// {
  # FinalBurn Neo's arcade DAT, which says which parent and BIOS sets a game
  # needs. From the commit before the FinalBurn Neo core in RomM 5.2's
  # EmulatorJS was built (June 2025), so the two agree.
  dat = fetchurl {
    name = "fbneo-arcade.dat";
    url = "https://raw.githubusercontent.com/libretro/FBNeo/e8291a39f637d23900d6998ea7f67648856201f9/dats/FinalBurn%20Neo%20(ClrMame%20Pro%20XML,%20Arcade%20only).dat";
    hash = "sha256-t7KscueASjvfpYAHW9nmvNXEQYabUrEli6GOkm/oQR0=";
  };
}
