{
  description = "lanbat homelab — server + Raspberry Pi 5";

  inputs = {
    # One nixpkgs for both hosts.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Raspberry Pi 5 hardware support.
    nixos-hardware.url = "github:NixOS/nixos-hardware";

    # Secrets as age-encrypted files (secrets/).
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Declarative disk layout, applied by nixos-anywhere at install time.
    disko = {
      url = "github:nix-community/disko/latest";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Deploys from a workstation, with automatic rollback.
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-hardware,
      agenix,
      disko,
      deploy-rs,
      ...
    }@inputs:
    let
      inherit (nixpkgs) lib;

      # local.nix holds the real settings and is gitignored, so it is only
      # visible through a path: flake reference (e.g. `deploy path:.#server`).
      # Without it the real hosts don't exist, and deploying them fails early.
      hasLocal = builtins.pathExists ./local.nix;

      mkHost =
        settings: modules:
        lib.nixosSystem {
          specialArgs = { inherit inputs; };
          modules = [
            agenix.nixosModules.default
            { nixpkgs.config.allowUnfree = true; }
            settings
          ]
          ++ modules;
        };

      mkServer =
        settings:
        mkHost settings [
          disko.nixosModules.disko
          ./hosts/server
        ];

      mkPi =
        settings:
        mkHost settings [
          nixos-hardware.nixosModules.raspberry-pi-5
          ./hosts/pi
        ];

      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in
    {
      nixosConfigurations = {
        example-server = mkServer ./hosts/example-settings.nix;
        example-pi = mkPi ./hosts/example-settings.nix;
      }
      // lib.optionalAttrs hasLocal {
        server = mkServer ./local.nix;
        pi = mkPi ./local.nix;
      };

      deploy.nodes = lib.optionalAttrs hasLocal {
        server = {
          hostname = self.nixosConfigurations.server.config.lanbat.serverIp;
          sshUser = "admin";
          user = "root";
          profiles.system.path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.server;
        };
        pi = {
          hostname = self.nixosConfigurations.pi.config.lanbat.piIp;
          sshUser = "admin";
          user = "root";
          # Build on the Pi itself rather than cross-compiling on the workstation.
          remoteBuild = true;
          profiles.system.path = deploy-rs.lib.aarch64-linux.activate.nixos self.nixosConfigurations.pi;
        };
      };

      checks.x86_64-linux = {
        assertions = import ./tests/assertions.nix { inherit lib pkgs; };
        postgresql = import ./tests/postgresql.nix { inherit pkgs; };
        workload-gate = import ./tests/workload-gate.nix { inherit pkgs; };
      }
      // lib.optionalAttrs hasLocal (deploy-rs.lib.x86_64-linux.deployChecks self.deploy);

      # `nix develop` provides the deploy, install and secrets tools.
      devShells.x86_64-linux.default = pkgs.mkShell {
        packages = [
          deploy-rs.packages.x86_64-linux.default
          agenix.packages.x86_64-linux.default
          pkgs.nixos-anywhere
        ];
      };

      # `nix fmt` formats every tracked .nix file; CI runs `nix fmt -- --ci`.
      formatter = lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (
        system: nixpkgs.legacyPackages.${system}.nixfmt-tree
      );
    };
}
