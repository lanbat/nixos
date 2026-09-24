# Extensibility

The lanbat NixOS flake is structured in three layers:

| Layer | What it is | Where it lives |
|---|---|---|
| **Deployment profile** | One site or environment (domain, hosts, secrets scope) | `deployments/<profile>/deploy.nix` |
| **Role** | Host-type infrastructure (server, storage-pi, voice-pi) | `lib/roles/` |
| **Plugin** | Optional features enabled per host | `plugins/` or external flake inputs |

## Deployment profiles (multi-site)

A **profile** is a self-contained site: its own domain, IP addresses, disks, and host list. You can run several profiles from one flake — a home lab and a vacation cabin, staging and production, two unrelated sites.

### Layout

```
deploy.nix                          # root manifest (gitignored) — lists active profiles
deployments/
  example/deploy.nix                # CI example (checked in)
  homelab/deploy.nix                # your primary site (gitignored)
  cabin/deploy.nix                  # second site (gitignored)
```

### Root manifest

```nix
# deploy.nix
{ inputs, ... }: {
  profiles = {
    homelab = import ./deployments/homelab/deploy.nix { inherit inputs; };
    cabin   = import ./deployments/cabin/deploy.nix   { inherit inputs; };
  };
}
```

Each profile file has the same shape as before: `{ deployment = { ... }; hosts = { ... }; }`.

### Flake output names

Hosts are exposed as `<profile>-<host-key>`:

| Profile | Host key | Flake attribute | deploy-rs node |
|---|---|---|---|
| `homelab` | `server` | `homelab-server` | `homelab-server` |
| `homelab` | `pi-storage` | `homelab-pi-storage` | `homelab-pi-storage` |
| `cabin` | `server` | `cabin-server` | `cabin-server` |

```bash
deploy path:.#homelab-server
deploy path:.#cabin-pi-storage
```

A single-profile setup that inlines `{ deployment, hosts }` directly in `deploy.nix` (without a `profiles` wrapper) uses the implicit profile name `default`, so host names stay `server` and `pi-storage`.

### Isolation between profiles

Each profile is fully independent:

- Separate `deployment.*` settings (domain, gateway, SSH key, …)
- Separate host keys and IP addresses
- Separate `nixosConfigurations` and `deploy.nodes` entries
- Hosts in one profile only see other hosts **in the same profile** via `config.lanbat.hosts` (cross-profile references are not supported)

Secrets (`secrets/*.age`) are still shared at the repo level; encrypt each secret for the agenix host keys of every profile that needs it.

## Roles

Roles bundle infrastructure modules for a host type. They are not optional — every host declares `role = "server"` (or `storage-pi`, `voice-pi`).

| Role | Purpose |
|---|---|
| `server` | LUKS layers, Caddy, databases, containers |
| `storage-pi` | Encrypted NVMe, NFS export, optional TV/voice plugins |
| `voice-pi` | Lightweight Wyoming satellite endpoint |

Add a new role by creating `lib/roles/<name>.nix` and registering it in `lib/roles.nix` and `modules/core/settings.nix`.

## Overlay providers

How hosts in a profile reach each other is chosen per profile with
`deployment.overlay.provider`. Each provider is a module that answers the
contract in `modules/core/overlay.nix`, registered by name in
`lib/overlay-providers.nix`. The name is read from deploy data before any module
is evaluated, so `lib/mkHost.nix` imports the chosen module directly. Adding a
provider means writing one module and adding one line to the registry.

| Provider | Fits | Needs | Gives up |
|---|---|---|---|
| `none` (default) | No overlay wanted; LAN traffic with generated allowlists | nothing | Isolation from the LAN segment |
| `wireguard-mesh` | 2–20 hosts you control, reachable from each other or through one that has an endpoint | `overlay.subnet`, `overlay.domain`, and per host `overlay.{ip,publicKey,endpoint?}` plus `secrets/overlay-<host>.age` | Hosts that roam between networks with nobody dialable |

A mesh profile, with keys from `nix run .#overlay-keys`:

```nix
deployment.overlay = {
  provider = "wireguard-mesh";
  subnet = "10.100.0.0/24";
  domain = "lanbat.internal";
};
hosts.server.overlay = {
  ip = "10.100.0.1";
  publicKey = "…";                     # printed by overlay-keys
  endpoint = "192.0.2.10:51820";       # this host can be dialled
};
hosts.pi-storage.overlay = {
  ip = "10.100.0.2";
  publicKey = "…";                     # no endpoint: dials out
};
```

A host without an `overlay` block stays off the mesh, and its edges stay on the
LAN. To pin one edge to the LAN whatever the profile runs, set
`endpoint.transport = "lan"` on the service. Tang and NFS never move: see
[architecture.md](architecture.md#overlay-network).

## Plugins

Plugins add optional features to compatible roles. Built-in plugins:

| Plugin | Roles | What it enables |
|---|---|---|
| `lanbatPlugins.services` | `server` | All homelab services |
| `lanbatPlugins.tv` | `storage-pi` | Kodi + EmulationStation |
| `lanbatPlugins.voice` | `storage-pi`, `voice-pi` | Wyoming satellite |
| `lanbatPlugins.android` | `server` | Provision Android TV boxes over ADB |
| `lanbatPlugins.xiaomi-clock` | `server` | Clock sync for Xiaomi BLE thermometers |

### External plugins

Add a flake input and reference it in a host's `plugins` list:

```nix
# flake.nix inputs
lanbat-media.url = "github:you/lanbat-media";

# deployments/homelab/deploy.nix
hosts.server.plugins = [
  inputs.self.lanbatPlugins.services
  inputs.lanbat-media.lanbatPlugin
];
```

See [plugins.md](plugins.md) for the plugin author contract (version 2: plugins
register their services for `hosts.<key>.services` to select, and declare their
own `deployment.<namespace>` settings). Version 1 plugins still load, with a
warning.

**Worked example — parking-guard.** The reference homelab adds
[*parking-guard*](https://github.com/lanbat/lanbat-justpark-parking), a Frigate-LPR
parking-enforcement service that watches Frigate plate detections and alerts when a
plate is not on the allowlist (JustPark bookings, a Luna CSV export, or a resident
list). It is wired entirely in the gitignored `deploy.nix`:

```nix
# flake.nix inputs
lanbat-justpark-parking = {
  url = "github:lanbat/lanbat-justpark-parking";
  inputs.nixpkgs.follows = "nixpkgs";
};

# deployments/homelab/deploy.nix
hosts.server.plugins = [
  inputs.self.lanbatPlugins.services
  inputs.lanbat-justpark-parking.lanbatPlugin
];

# plugin-specific options (schema in modules/core/settings.nix)
deployment.parkingGuard = {
  siteId = "…";              # JustPark site id
  cameras = [ "driveway" ];  # Frigate camera names to watch
  graceMinutes = 5;
  cooldownMinutes = 30;
  residentPlates = [ ];
};
```

It runs as a small set of systemd units on the server: a continuous LPR evaluator
(`parking-guard.service`), a JustPark/CSV allowlist sync timer
(`parking-guard-sync.*`), and a CSV-import path unit
(`parking-guard-csv-import.*`).

## Local modules

A fork often needs a change no option covers: a firewall rule, a package, an
override of a service's configuration. Rather than editing a tracked file, put
a NixOS module in the deployment's `local/` directory, which is gitignored:

```
deployments/<profile>/local/*.nix              # every host of the profile
deployments/<profile>/local/hosts/<key>/*.nix  # host <key> only
```

Each `.nix` file directly in those directories is imported, in name order,
profile-wide files first; anything else, such as a subdirectory holding a
module's data, is left alone. They are merged after every other module source,
including a host's `modules` list in the deploy file, so they can override
anything core, a role or a plugin sets. A single-profile `deploy.nix` without a
`profiles` wrapper uses `deployments/default/local/`.

```nix
# deployments/homelab/local/hosts/server/firewall.nix
{ ... }:
{
  networking.firewall.allowedTCPPorts = [ 25565 ];
}
```

Because the directory is untracked, a flake evaluated from git (`.#`, and CI)
does not see it; evaluate and deploy the real site from the working tree
(`path:.`), as you already do for `deploy.nix`. With no `local/` directory
nothing changes, which is why the example profile is unaffected.

## Multiple machines per profile

Within one profile you can declare any number of hosts:

```nix
hosts = {
  server = { role = "server"; ... };
  pi-storage = { role = "storage-pi"; ... };
  pi-bedroom = { role = "voice-pi"; ... };
  pi-garage   = { role = "voice-pi"; ... };
};
```

Services that use Pi storage declare which storage host to mount from:

```nix
lanbat.services.jellyfin.nfs = {
  storageHost = "pi-storage";  # defaults to primary storage-pi
  drives = [ "a" "b" ];        # keys of that host's storage.drives
};
```

A storage host's drives are the keys of `hosts.<key>.storage.drives`, one or more,
named with lowercase letters and digits. See
[storage-layout.md](storage-layout.md#drives-are-named-not-counted).

Voice satellites map Home Assistant areas to host keys:

```nix
deployment.voiceRooms = {
  "Living Room" = "pi-storage";
  "Bedroom"     = "pi-bedroom";
  "Office"      = "server";
};
```

### Example: storage Pi + bedroom voice Pi

A profile with one storage host and one voice satellite:

```nix
# deployments/homelab/deploy.nix
hosts = {
  server = {
    role = "server";
    plugins = [ inputs.self.lanbatPlugins.services ];
    # ...
  };
  pi-storage = {
    role = "storage-pi";
    plugins = [
      inputs.self.lanbatPlugins.tv
      inputs.self.lanbatPlugins.voice
    ];
    # ...
  };
  pi-bedroom = {
    role = "voice-pi";
    plugins = [ inputs.self.lanbatPlugins.voice ];
    # ...
  };
};

deployment.voiceRooms = {
  "Living Room" = "pi-storage";
  "Bedroom"     = "pi-bedroom";
};
```

Services on the server that mount Pi storage point at the storage host explicitly:

```nix
# services/jellyfin.nix (or any lanbat.services.*.nfs)
lanbat.services.jellyfin.nfs = {
  storageHost = "pi-storage";
  drives = [ "a" "b" ];
};
```

Match agenix recipients in `secrets/secrets.nix` to those host keys:

```nix
let
  server     = "ssh-ed25519 ..."; # hosts.server
  pi-storage = "ssh-ed25519 ..."; # hosts.pi-storage
  pi-bedroom = "ssh-ed25519 ..."; # hosts.pi-bedroom
  admin      = "ssh-ed25519 ...";

  serverKeys = [ server admin ];
  allPis     = [ pi-storage pi-bedroom ];
  allKeys    = serverKeys ++ allPis;
in
{
  "telegraf-token.age".publicKeys = allKeys;
  "ha-voice-token.age".publicKeys = allKeys;
  # everything else → serverKeys
}
```

Deploy each host independently:

```bash
deploy path:.#homelab-server
deploy path:.#homelab-pi-storage
deploy path:.#homelab-pi-bedroom
```

See [secrets/README.md](../secrets/README.md) for multi-Pi and multi-profile
recipient patterns.

## Tooling

Flake apps help validate deployment files and query values from scripts:

| Command | Purpose |
|---|---|
| `nix run .#validate-deploy` | Run deploy/profile validation checks (same as the CI check) |
| `nix run .#hosts` | List flake host names and IPs across active profiles |
| `nix run .#deploy-query -- server-ip` | Print the primary server IP (optional second arg: profile name) |

Other `deploy-query` keys: `domain`, `profile`, `flake-server`, `immich-admin-email`,
`host-ips`, `deploy-file`. Example:

```bash
nix run .#deploy-query -- domain homelab
nix run .#deploy-query -- deploy-file cabin
```

`secrets/lib/read-deploy.sh` and other scripts delegate to `deploy-query` instead
of parsing `deploy.nix` by hand.
