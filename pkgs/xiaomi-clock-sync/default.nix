{
  stdenv,
  python3,
}:

let
  python = python3.withPackages (ps: [ ps.bleak ]);
in
stdenv.mkDerivation {
  pname = "xiaomi-clock-sync";
  version = "1.0";

  src = ./sync.py;

  dontUnpack = true;

  installPhase = ''
    install -Dm755 $src $out/bin/xiaomi-clock-sync
    substituteInPlace $out/bin/xiaomi-clock-sync \
      --replace-fail '#!/usr/bin/env python3' '#!${python}/bin/python3'
  '';

  meta = {
    description = "Set the clock on Xiaomi BLE thermometers over Bluetooth";
    mainProgram = "xiaomi-clock-sync";
  };
}
