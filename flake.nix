{
  description = "lanbat homelab — server + pi5";

  # ---------------------------------------------------------------------------
  # Inputs
  # ---------------------------------------------------------------------------
  inputs = {
    # Stable channel — kept as a reference but the server now uses unstable.
    # The Pi still uses stable for maximum reliability on embedded hardware.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

    # Unstable channel — server runs on this for up-to-date security fixes
    # and features (rootless Podman support in oci-containers, latest packages).
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Temporary: needed only for the Nextcloud 30→31→32 upgrade path.
    # nixpkgs-unstable has removed NC31 (minimum is NC32), so we fetch NC31
    # from the 25.11 stable channel.  Remove this input once the server DB
    # has been migrated to NC31 and the package is switched to nextcloud32.
    nixpkgs-2511.url = "github:NixOS/nixpkgs/nixos-25.11";

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
  outputs = { self, nixpkgs, nixpkgs-unstable, nixpkgs-2511, nixos-hardware, agenix, ... }@inputs:
  let
    # Expose stable packages as pkgs.stable in every module (for Pi compat).
    stableOverlay = final: prev: {
      stable = import nixpkgs {
        system = prev.system;
        config.allowUnfree = true;
      };
    };

    # Legacy alias: pkgs.unstable still works, now points to unstable itself
    # (a no-op overlay on the unstable base, kept for backwards compat).
    unstableOverlay = final: prev: {
      unstable = prev;
    };

    # Server pkgs: based on unstable for security-forward package set.
    mkServerPkgs = system: import nixpkgs-unstable {
      inherit system;
      config.allowUnfree = true;
      overlays = [
        stableOverlay
        unstableOverlay
        (import ./overlays)
      ];
    };

    # Pi pkgs: based on stable for maximum reliability on embedded hardware.
    # allowBroken: wyoming-satellite depends on pysilero-vad which is marked
    # broken in 24.11; allow it until the Pi is upgraded to a newer channel.
    mkPiPkgs = system: import nixpkgs {
      inherit system;
      config.allowUnfree = true;
      config.allowBroken = true;
      overlays = [
        (final: prev: {
          unstable = import nixpkgs-unstable {
            system = prev.system;
            config.allowUnfree = true;
          };
        })
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
      server = nixpkgs-unstable.lib.nixosSystem {
        system = "x86_64-linux";
        pkgs   = mkServerPkgs "x86_64-linux";
        specialArgs = {
          inherit inputs;
          # nextcloud31 from 25.11 stable for the NC30→31→32 upgrade hop.
          # Remove once DB is migrated to NC31 and package is nextcloud32.
          pkgs-2511 = import nixpkgs-2511 {
            system = "x86_64-linux";
            config = {
              allowUnfree = true;
              # NC31 is marked insecure in 25.11 (EOL).  Permitted temporarily
              # for the NC30→31 upgrade step only.
              permittedInsecurePackages = [ "nextcloud-31.0.14" ];
            };
          };
        };
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
        pkgs   = mkPiPkgs "aarch64-linux";
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
