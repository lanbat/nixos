# Plugin author guide

Third-party features ship as flake inputs that export a `lanbatPlugin` attribute.

## Minimal plugin

A copy-pasteable template lives in
[`examples/lanbat-plugin-minimal/`](../examples/lanbat-plugin-minimal/).

```nix
# flake.nix outputs
{
  lanbatPlugin = {
    name = "lanbat-media";
    version = 1;
    roles = [ "server" ];
    modules = [
      ./services/jellyfin.nix
      ./services/immich.nix
    ];
  };
}
```

## Contract

| Field | Required | Description |
|---|---|---|
| `name` | yes | Unique plugin identifier |
| `version` | yes | Integer schema version (currently `1`) |
| `roles` | yes | Host roles that may enable this plugin |
| `modules` | yes | List of NixOS modules (non-empty) |

Validation happens at evaluation time in `lib/plugins.nix`:

- A plugin whose `roles` do not include the host's role fails evaluation.
- A plugin with no modules fails evaluation.

## Service modules

Server plugins should declare services under `lanbat.services.<name>` using the interface in `modules/core/services.nix`. The wiring modules (`modules/wiring/`) generate Caddy vhosts, LUKS gating, NFS dependencies, accounts, and secrets from those declarations.

## Consuming a plugin

```nix
# flake.nix
inputs.lanbat-media.url = "github:you/lanbat-media";
inputs.lanbat-media.inputs.nixpkgs.follows = "nixpkgs";

# deployments/homelab/deploy.nix
hosts.server.plugins = [
  inputs.self.lanbatPlugins.services
  inputs.lanbat-media.lanbatPlugin
];
```

## Secrets

Plugins use the repo's agenix `secrets/` directory. If your plugin needs new
secrets:

1. Declare them under `lanbat.services.<name>.secrets` (or `age.secrets` for
   non-service secrets).
2. Add entries to `secrets/secrets.nix.example` and the inventory in
   `secrets/README.md`.
3. **In your pull request:** commit an empty placeholder at each
   `secrets/<name>.age` path so evaluation passes, and document the required
   secrets in your plugin README (format, how to generate values).
4. **Before merge:** the lanbat maintainer replaces placeholders with real
   `.age` files encrypted to the deployment host keys (see
   [CONTRIBUTING.md](../CONTRIBUTING.md)).

## Exported modules

The core flake also exports reusable NixOS modules for plugin authors:

```nix
inputs.lanbat.url = "github:lanbat/nixos";
# inputs.lanbat.inputs.nixpkgs.follows = "nixpkgs";

imports = [
  inputs.lanbat.nixosModules.lanbat
];
```

Available modules: `lanbat`, `lanbat-server`, `lanbat-storage-pi`, `lanbat-voice-pi`.
