{
  description = "lanbat homelab — server + pi5";

  # ---------------------------------------------------------------------------
  # Inputs
  # ---------------------------------------------------------------------------
  inputs = {
    # Stable channel. Bump to nixos-25.05 once it is released.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

    # Occasional unstable package overrides — available as pkgs.unstable.<name>.
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Raspberry Pi hardware quirks (including Pi 5).
    nixos-hardware.url = "github:NixOS/nixos-hardware";

    # Secret management via age-encrypted files.
    # Each host's public key lives in secrets/keys/.
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  # ---------------------------------------------------------------------------
  # Outputs
  # ---------------------------------------------------------------------------
  outputs = { self, nixpkgs, nixpkgs-unstable, nixos-hardware, agenix, ... }@inputs:
  let
    # Expose unstable packages as pkgs.unstable in every module.
    unstableOverlay = final: prev: {
      unstable = import nixpkgs-unstable {
        system = prev.system;
        config.allowUnfree = true;
      };
    };

    # Build a pkgs set with our overlays.
    mkPkgs = system: import nixpkgs {
      inherit system;
      config.allowUnfree = true;
      overlays = [
        unstableOverlay
        (import ./overlays)
      ];
    };

    # Per-deployment local settings (gitignored, see local.nix.example).
    # Only visible when deploying with --impure; absent in CI (pure eval).
    # In CI the placeholder defaults from modules/common/settings.nix are used.
    localModules = nixpkgs.lib.optional (builtins.pathExists ./local.nix) ./local.nix;
  in
  {
    nixosConfigurations = {
      # -----------------------------------------------------------------
      # Main server (x86_64)
      # -----------------------------------------------------------------
      server = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        pkgs   = mkPkgs "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          agenix.nixosModules.default
          ./hosts/server
        ] ++ localModules;
      };

      # -----------------------------------------------------------------
      # Raspberry Pi 5 (aarch64)
      # -----------------------------------------------------------------
      pi = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        pkgs   = mkPkgs "aarch64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          agenix.nixosModules.default
          nixos-hardware.nixosModules.raspberry-pi-5
          ./hosts/pi
        ] ++ localModules;
      };
    };

    # Convenience: `nix fmt` formats all .nix files.
    formatter.x86_64-linux  = nixpkgs.legacyPackages.x86_64-linux.nixfmt-rfc-style;
    formatter.aarch64-linux = nixpkgs.legacyPackages.aarch64-linux.nixfmt-rfc-style;
  };
}
