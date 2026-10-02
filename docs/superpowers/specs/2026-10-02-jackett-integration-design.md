# Jackett and qBittorrent Integration Design

## Purpose

Add Jackett as the server's indexer aggregator so qBittorrent searches its
configured indexers through Jackett's API.  The Jackett management interface
is available at `jackett.<domain>` only to the `authentik Admins` group.

## Service model

Jackett uses the NixOS-native `services.jackett` module, rather than another
container.  It listens on its default port, 9117, with private/local access;
the firewall does not expose that port.  Caddy proxies the public hostname to
the local service, and its existing generated Authentik forward-auth
integration limits access to `authentik Admins`.

The UI has no Jackett-specific user accounts or roles.  Authentik is therefore
the sole interactive access control.  Every accepted user has Jackett's full
management capability, which is why the route is admin-only.

## State, lifecycle, and backup

Jackett's data directory holds the configured indexers, private-indexer
credentials, cookies, and its API key.  It is workload-tier state at
`/var/lib/jackett`, so it is unavailable while the encrypted workload layer is
locked and is included in the server backup.

The service is declared with the workload-gate metadata and starts only after
the workload layer is unlocked.  No NFS dependency is needed: Jackett searches
remote indexers and retains only its configuration locally.

## qBittorrent API integration

qBittorrent already has the Jackett search plugin and a generated
`/var/lib/qbittorrent/qBittorrent/nova3/engines/jackett.json` configuration
file.  A workload-gated one-shot initializer runs after Jackett has generated
its server configuration and before qBittorrent starts.  It reads Jackett's
locally generated API key and atomically writes qBittorrent's plugin
configuration:

- API URL: `http://127.0.0.1:9117`
- API key: the current Jackett-generated key
- `tracker_first`: `false`
- `thread_count`: `20`

The initializer writes the file with qBittorrent's service account ownership
and restrictive permissions.  qBittorrent is ordered after both Jackett and
the initializer, ensuring the plugin never starts with the placeholder key.
If Jackett regenerates its key, restarting the workload services reruns the
initializer and updates qBittorrent before it starts.

## Files and documentation

Implementation adds `services/jackett.nix`, registers it in
`plugins/services/registry.nix`, and enables it in the applicable deployment
alongside qBittorrent.  It updates architecture, secure-layer, storage,
backup, failure-mode, and operational documentation to cover the hostname,
encrypted state, backup path, unlock lifecycle, API relationship, and
administrator setup steps.

## Verification

Evaluation must confirm the example deployment accepts the service metadata
and all generated wiring.  Focused checks verify the new service description,
workload units, forward-auth admin-group restriction, and qBittorrent ordering.
The normal Nix formatting and relevant evaluation/check commands are run before
completion.
