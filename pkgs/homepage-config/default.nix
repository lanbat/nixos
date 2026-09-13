{ pkgs }:

{
  generateServicesYaml = pkgs.writeShellScript "homepage-config-gen" ''
    set -euo pipefail
    exec ${pkgs.python3}/bin/python3 ${./generate-services-yaml.py} "$1" "$2" "$3"
  '';

  createHaToken = pkgs.writeShellScript "homepage-create-ha-token" ''
    set -euo pipefail
    exec ${pkgs.python3}/bin/python3 ${./create-ha-token.py}
  '';
}
