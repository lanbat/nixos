{
  description = "Minimal lanbat plugin example";
  inputs.lanbat.url = "github:lanbat/nixos";
  outputs = { self, ... }: {
    lanbatPlugin = {
      name = "example-noop";
      version = 1;
      roles = [ "server" ];
      modules = [ ./module.nix ];
    };
  };
}
