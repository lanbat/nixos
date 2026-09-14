{
  description = "lanbat homelab — server + Raspberry Pi 5";

  inputs = {
    # nixpkgs of the server. The Pi uses nixos-raspberrypi's own pinned nixpkgs
    # (see mkPi), because its binary cache only has the Raspberry Pi kernel and
    # firmware built for that nixpkgs.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Raspberry Pi 5 support: vendor kernel, firmware and the firmware-partition
    # bootloader. Doesn't follow our nixpkgs, to keep its binary cache usable.
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/main";

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
      nixos-raspberrypi,
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

      # nixos-raspberrypi's nixosSystem uses its pinned nixpkgs and trusts its
      # binary cache, so the Pi downloads its kernel instead of compiling it.
      mkPi =
        settings:
        nixos-raspberrypi.lib.nixosSystem {
          specialArgs = { inherit inputs nixos-raspberrypi; };
          modules = [
            agenix.nixosModules.default
            { nixpkgs.config.allowUnfree = true; }
            settings
            ./hosts/pi
            ./hosts/pi/hardware.nix
          ];
        };

      pkgs = nixpkgs.legacyPackages.x86_64-linux;

      # deploy-rs's library, with nixpkgs' deploy-rs, which is in the binary
      # cache. The flake input's own package is built from source against our
      # nixpkgs, and crates.io refuses to serve some of its dependencies.
      deployLib =
        system:
        (import nixpkgs {
          inherit system;
          overlays = [
            deploy-rs.overlays.default
            (final: prev: {
              deploy-rs = {
                inherit (nixpkgs.legacyPackages.${system}) deploy-rs;
                inherit (prev.deploy-rs) lib;
              };
            })
          ];
        }).deploy-rs.lib;
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
          profiles.system.path = (deployLib "x86_64-linux").activate.nixos self.nixosConfigurations.server;
        };
        pi = {
          hostname = self.nixosConfigurations.pi.config.lanbat.piIp;
          sshUser = "admin";
          user = "root";
          # Build on the Pi itself rather than cross-compiling on the workstation.
          remoteBuild = true;
          profiles.system.path = (deployLib "aarch64-linux").activate.nixos self.nixosConfigurations.pi;
        };
      };

      checks.x86_64-linux = {
        assertions = import ./tests/assertions.nix { inherit lib pkgs; };
        music-assistant = import ./tests/music-assistant.nix { inherit pkgs; };
        pkgs-build = import ./tests/pkgs-build.nix { inherit pkgs; };
        postgresql = import ./tests/postgresql.nix { inherit pkgs; };
        settings-guard = import ./tests/settings-guard.nix { inherit lib pkgs; };
        server = import ./tests/server.nix {
          inherit pkgs;
          inherit (inputs) agenix disko;
        };
        workload-gate = import ./tests/workload-gate.nix { inherit pkgs; };
      }
      // lib.optionalAttrs hasLocal ((deployLib "x86_64-linux").deployChecks self.deploy);

      # Runs on an aarch64 machine with KVM (the Pi itself), with the Pi's nixpkgs.
      checks.aarch64-linux.pi = import ./tests/pi.nix {
        pkgs = nixos-raspberrypi.inputs.nixpkgs.legacyPackages.aarch64-linux;
        inherit (inputs) agenix;
      };

      # `nix develop` provides the deploy, install and secrets tools.
      devShells.x86_64-linux.default = pkgs.mkShell {
        packages = [
          pkgs.deploy-rs
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
