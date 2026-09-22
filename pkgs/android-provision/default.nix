{
  stdenv,
  lib,
  python3,
  android-tools,
  makeWrapper,
}:

let
  python = python3.withPackages (ps: [ ps.pyaxmlparser ]);
  # Separate check-only interpreter so pytest never ends up in the runtime
  # closure: a `withPackages` wrapper only sees the packages named in its own
  # list, so `checkInputs` alone would not put pytest on PATH for it.
  pythonCheck = python3.withPackages (ps: [
    ps.pyaxmlparser
    ps.pytest
  ]);
in
stdenv.mkDerivation {
  pname = "android-provision";
  version = "1.0";

  src = ./.;

  # pythonCheck is on PATH here so patchShebangs (below) can resolve `python3`.
  nativeBuildInputs = [
    makeWrapper
    pythonCheck
  ];

  # tests/fake_adb.py has a `#!/usr/bin/env python3` shebang; conftest.py
  # copies it to a fake `adb` binary and execs it, but the build sandbox has
  # no /usr/bin/env. Rewrite the shebang to an absolute store path so that
  # copy stays runnable.
  postPatch = ''
    patchShebangs tests/fake_adb.py
  '';

  doCheck = true;

  # The suite drives the runner against tests/fake_adb.py, so it needs no
  # device and no network -- which the sandbox would deny anyway.
  checkPhase = ''
    runHook preCheck
    PYTHONPATH=$PWD/src ${pythonCheck}/bin/python3 -m pytest tests/ -q
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib
    cp -r src/android_provision $out/lib/

    makeWrapper ${python}/bin/python3 $out/bin/android-provision \
      --add-flags "-m android_provision.cli" \
      --set PYTHONPATH "$out/lib" \
      --prefix PATH : ${lib.makeBinPath [ android-tools ]}

    install -Dm644 ${./apks.lock.json} $out/share/android-provision/apks.lock.json

    runHook postInstall
  '';

  meta = {
    description = "Provision Android TV boxes over ADB from a Nix-built manifest";
    mainProgram = "android-provision";
  };
}
