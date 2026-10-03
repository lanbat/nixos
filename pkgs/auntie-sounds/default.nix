{
  python3Packages,
}:

# Music Assistant's BBC Sounds provider needs it, and nixpkgs does not package
# it yet ("missing auntie-sounds" in the music-assistant package's providers).
# Pure Python; the wheel is the version the provider pins (MA 2.7.x).
python3Packages.buildPythonPackage rec {
  pname = "auntie-sounds";
  version = "1.1.7";
  format = "wheel";

  src = python3Packages.fetchPypi {
    pname = "auntie_sounds";
    inherit version format;
    dist = "py3";
    python = "py3";
    sha256 = "b04fc0e20e3981d3a592131a21ba181dadc005f69c7fcfd17131ed5e5fc83ac1";
  };

  dependencies = with python3Packages; [
    aiohttp
    appdirs
    attrs
    beautifulsoup4
    colorlog
    pytz
    typing-extensions
    yarl
  ];

  # Imports only: its tests are not in the wheel.
  pythonImportsCheck = [ "sounds" ];

  doCheck = false;
}
