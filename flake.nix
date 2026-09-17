{
  description = "lanbat homelab — extensible multi-machine NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/main";

    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko/latest";
      inputs.nixpkgs.follows = "nixpkgs";
    };

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

      lanbatPlugins = {
        services = import ./plugins/services;
        tv = import ./plugins/tv;
        voice = import ./plugins/voice;
      };

      inputsWithSelf = inputs // {
        self = self // {
          inherit lanbatPlugins;
        };
      };

      loadDeployments = import ./lib/load-deployments.nix { inherit lib; };

      hasDeploy = builtins.pathExists ./deploy.nix;

      deployRaw =
        if hasDeploy then
          import ./deploy.nix { inputs = inputsWithSelf; }
        else
          import ./deployments/example/deploy.nix { inputs = inputsWithSelf; };

      profiles =
        if hasDeploy then
          loadDeployments.normalize deployRaw
        else
          {
            example = import ./deployments/example/deploy.nix { inputs = inputsWithSelf; };
          };

      lanbatLib = import ./lib {
        self = inputsWithSelf.self;
        inputs = inputsWithSelf;
        inherit
          nixpkgs
          nixos-raspberrypi
          agenix
          disko
          deploy-rs
          profiles
          hasDeploy
          ;
        root = ./.;
      };

      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in
    {
      inherit lanbatPlugins;

      lib.lanbat = {
        inherit (lanbatLib)
          hostsWithRole
          primaryHost
          hostIp
          hostHostname
          hostInterface
          voiceRoomForHost
          validatePlugin
          resolvePlugins
          mkHost
          mkProfile
          hostFlakeName
          deployLib
          deployQuery
          ;
        loadDeployments = loadDeployments.normalize;
      };

      nixosModules = {
        lanbat = ./modules/core;
        lanbat-server = ./lib/roles/server.nix;
        lanbat-storage-pi = ./lib/roles/storage-pi.nix;
        lanbat-voice-pi = ./lib/roles/voice-pi.nix;
      };

      nixosConfigurations = lanbatLib.configurations;

      deploy.nodes = if hasDeploy then lanbatLib.deployNodes else { };

      checks.x86_64-linux = {
        assertions = import ./tests/assertions.nix { inherit lib pkgs; };
        music-assistant = import ./tests/music-assistant.nix { inherit pkgs; };
        pkgs-build = import ./tests/pkgs-build.nix { inherit pkgs; };
        plugins = import ./tests/plugins.nix { inherit lib pkgs; };
        postgresql = import ./tests/postgresql.nix { inherit pkgs; };
        settings-guard = import ./tests/settings-guard.nix { inherit lib pkgs; };
        validate-deploy = import ./tests/validate-deploy.nix { inherit lib pkgs; };
        load-deployments = import ./tests/load-deployments.nix {
          inherit
            lib
            pkgs
            inputs
            self
            agenix
            disko
            deploy-rs
            nixpkgs
            nixos-raspberrypi
            ;
        };
        deploy-rs-fixture = import ./tests/deploy-rs-fixture.nix {
          inherit
            lib
            pkgs
            inputs
            self
            agenix
            disko
            deploy-rs
            nixpkgs
            nixos-raspberrypi
            ;
        };
        server = import ./tests/server.nix {
          inherit pkgs;
          inherit (inputs) agenix disko;
        };
        workload-gate = import ./tests/workload-gate.nix { inherit pkgs; };
      }
      // lib.optionalAttrs hasDeploy (
        (lanbatLib.deployLib "x86_64-linux").deployChecks { nodes = lanbatLib.deployNodes; }
      );

      checks.aarch64-linux = {
        pi = import ./tests/pi.nix {
          pkgs = nixos-raspberrypi.inputs.nixpkgs.legacyPackages.aarch64-linux;
          inherit (inputs)
            agenix
            nixpkgs
            nixos-raspberrypi
            disko
            ;
          inputs = inputsWithSelf;
        };

        voice-pi = import ./tests/voice-pi.nix {
          pkgs = nixos-raspberrypi.inputs.nixpkgs.legacyPackages.aarch64-linux;
          inherit (inputs)
            agenix
            nixpkgs
            nixos-raspberrypi
            disko
            ;
          inputs = inputsWithSelf;
        };
      };

      devShells.x86_64-linux.default = pkgs.mkShell {
        packages = [
          pkgs.deploy-rs
          agenix.packages.x86_64-linux.default
          pkgs.nixos-anywhere
        ];
      };

      formatter = lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (
        system: nixpkgs.legacyPackages.${system}.nixfmt-tree
      );

      apps.x86_64-linux = {
        deploy-query = {
          type = "app";
          program = toString (
            pkgs.writeShellScript "deploy-query" ''
              set -euo pipefail
              KEY="''${1:?usage: deploy-query <key> [profile]}"
              PROFILE="''${2:-}"
              REF=".#lib.lanbat.deployQuery.\"''${KEY}\""
              if [ -n "''$PROFILE" ]; then
                exec ${pkgs.nix}/bin/nix eval --raw --apply "f: f \"''$PROFILE\"" "''$REF"
              else
                exec ${pkgs.nix}/bin/nix eval --raw --apply "f: f null" "''$REF"
              fi
            ''
          );
        };

        hosts = {
          type = "app";
          program = toString (
            pkgs.writeShellScript "hosts" ''
              exec ${pkgs.nix}/bin/nix eval --raw --apply "f: f null" .#lib.lanbat.deployQuery.hosts
            ''
          );
        };

        validate-deploy = {
          type = "app";
          program = toString (
            pkgs.writeShellScript "validate-deploy" ''
              exec ${pkgs.nix}/bin/nix build .#checks.x86_64-linux.validate-deploy --no-link
            ''
          );
        };
      };
    };
}
