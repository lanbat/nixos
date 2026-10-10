# pkgs/frigate-person-mapper
#
# Frigate's face recognition, made into room presence: who is in which room.
# Reports to the assistant router (body socket) and Home Assistant. See
# services/person-mapper.nix.
{ python3Packages }:

python3Packages.buildPythonApplication {
  pname = "frigate-person-mapper";
  version = "1.0";
  pyproject = true;
  src = ./.;
  build-system = [ python3Packages.setuptools ];
  dependencies = [
    python3Packages.paho-mqtt
    python3Packages.websockets
  ];
  nativeCheckInputs = [ python3Packages.pytestCheckHook ];
  meta.mainProgram = "frigate-person-mapper";
}
