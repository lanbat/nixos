# Migration from local.nix

The monolithic `local.nix` has been replaced by deployment profiles.

## Quick start

```bash
# 1. Create a profile for your site
mkdir -p deployments/homelab
cp deployments/homelab/deploy.nix.example deployments/homelab/deploy.nix

# 2. Create the root manifest
cp deploy.nix.example deploy.nix
# Edit deploy.nix to import deployments/homelab/deploy.nix

# 3. Fill in deployments/homelab/deploy.nix with your values

# 4. Deploy (profile-prefixed names)
deploy path:.#homelab-server
deploy path:.#homelab-pi-storage
```

## Field mapping

| Old (`local.nix`) | New |
|---|---|
| `lanbat.serverIp` | `hosts.server.networking.ip` in profile deploy |
| `lanbat.piIp` | `hosts.pi-storage.networking.ip` |
| `lanbat.serverDisk` | `hosts.server.disks.system` |
| `lanbat.piStorageDriveA/B` | `hosts.pi-storage.storage.drives.a/b` (any number of drives, named by key) |
| `lanbat.piTvFrontend` | enable `lanbatPlugins.tv` on that host |
| `lanbat.voiceRooms.server` | `deployment.voiceRooms."Office" = "server"` |
| `lanbat.voiceRooms.pi` | `deployment.voiceRooms."Living Room" = "pi-storage"` |
| Service imports in host file | `hosts.server.plugins = [ ... ]` |
| `deploy path:.#server` | `deploy path:.#homelab-server` |

## Single profile (no prefix)

If you inline `{ deployment, hosts }` directly in `deploy.nix` without a `profiles` wrapper, the implicit profile name is `default` and host names stay `server`, `pi-storage`, etc.

## Multiple sites

Add one `deployments/<site>/deploy.nix` per site and list them in the root `deploy.nix`:

```nix
{ inputs, ... }: {
  profiles = {
    homelab = import ./deployments/homelab/deploy.nix { inherit inputs; };
    cabin   = import ./deployments/cabin/deploy.nix   { inherit inputs; };
  };
}
```

Each site gets independent domains, IPs, and host keys. Deploy with `path:.#<profile>-<host>`.

## Clean up

After you have verified the new profile deploys work, delete the legacy
`local.nix` at the repo root. It is no longer read by the flake.
