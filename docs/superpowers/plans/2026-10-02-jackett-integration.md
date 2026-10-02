# Jackett Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an Authentik-admin-only, workload-gated Jackett service and configure qBittorrent’s Jackett search plugin with its local API key.

**Architecture:** A native NixOS `services.jackett` instance retains all indexer credentials and API state in the encrypted workload layer. Generated Caddy and Authentik wiring publish its management UI only to `authentik Admins`; a gated initializer copies the generated API key into qBittorrent’s plugin configuration before the torrent container starts.

**Tech Stack:** NixOS modules, systemd, Caddy, Authentik blueprints, qBittorrent Nova3 search plugins, Nix evaluation tests.

**Spec:** `docs/superpowers/specs/2026-10-02-jackett-integration-design.md`

## Global Constraints

- Use NixOS-native `services.jackett`; do not add a container.
- Keep Jackett’s port 9117 out of the firewall and use local/private listener mode.
- Store `/var/lib/jackett` on the workload LUKS layer.
- Restrict the Caddy route to `authentik Admins`; Jackett has no non-admin role.
- qBittorrent must use `http://127.0.0.1:9117` and Jackett’s generated API key.
- Never place the API key or indexer credentials in the Nix store or repository.
- Preserve pre-existing edits, particularly in `docs/operations.md` and
  `tests/service-settings.nix`; use patch staging for those files and commit
  only the Jackett hunks.

## Review Focus

- A locked workload layer must leave `/var/lib/jackett` an inaccessible stub and must not start Jackett or qBittorrent.
- The generated Caddy route must require forward-auth and the Authentik blueprint must bind it to `authentik Admins`.
- Port 9117 must not appear in `networking.firewall.allowedTCPPorts`.
- qBittorrent must start only after the API-key initializer, not merely after Jackett.
- A regenerated/missing `jackett.json` must be atomically recreated with `qbt:qbt` ownership and mode `0600`.

---

### Task 1: Add the Jackett service declaration and generated access control

**Files:**
- Create: `services/jackett.nix`
- Modify: `plugins/services/registry.nix`
- Modify: `tests/service-settings.nix`
- Modify: `tests/caddy-audit.nix`
- Modify: `tests/authentik-catalogue.nix`

**Interfaces:**
- Consumes: `lanbat.services.<name>` metadata, `services.jackett`, and generated Caddy/AuthentiK wiring.
- Produces: `lanbat.services.jackett`, with `subdomain = "jackett"`, `port = 9117`, `auth = "forward-auth"`, `access.groups = [ "authentik Admins" ]`, `tier = "workload"`, `state = [ "jackett" ]`, and `units = [ "jackett" "jackett-qbittorrent-plugin" ]`.

- [ ] **Step 1: Write failing evaluation assertions**

Add declarations in `tests/service-settings.nix` that inspect the example host:

```nix
jackett = base.lanbat.services.jackett;
jackettService = base.services.jackett;
jackettUnit = base.systemd.services.jackett;
```

Add a case requiring the exact public and storage contract:

```nix
(expect "jackett: workload-native service stays private behind admin forward auth" (
  jackett.subdomain == "jackett"
  && jackett.port == 9117
  && jackett.auth == "forward-auth"
  && jackett.access.groups == [ "authentik Admins" ]
  && jackett.tier == "workload"
  && jackett.state == [ "jackett" ]
  && jackett.units == [ "jackett" "jackett-qbittorrent-plugin" ]
  && jackettService.enable
  && !jackettService.openFirewall
  && lib.elem "workload-online.target" jackettUnit.wantedBy
))
```

Extend `tests/caddy-audit.nix` to retrieve `vhostOf "jackett"` and assert it has no auth bypass and strips `X-Authentik-Username`. Extend `tests/authentik-catalogue.nix`’s expected proxied names and display-name map with:

```nix
"jackett"
jackett = "Jackett";
```

- [ ] **Step 2: Run the focused checks and confirm failure**

Run:

```bash
nix build -L .#checks.x86_64-linux.{service-settings,caddy-audit,authentik-catalogue}
```

Expected: evaluation fails because `lanbat.services.jackett` and its generated route/provider do not yet exist.

- [ ] **Step 3: Implement the native service module**

Create `services/jackett.nix` with the repository’s standard service description:

```nix
{ config, lib, ... }:
{
  lanbat.services.jackett = {
    subdomain = "jackett";
    port = 9117;
    auth = "forward-auth";
    access.groups = lib.mkDefault [ "authentik Admins" ];
    tier = "workload";
    state = [ "jackett" ];
    units = [ "jackett" "jackett-qbittorrent-plugin" ];
    dashboard = {
      group = "Downloads";
      name = "Jackett";
      description = "Torrent indexer aggregator";
    };
  };

  services.jackett = {
    enable = true;
    port = config.lanbat.services.jackett.port;
    openFirewall = false;
    dataDir = "/var/lib/jackett/.config/Jackett";
  };
}
```

Ensure the Jackett process receives its normal private-listener mode (the module’s default; do not add `--ListenPublic`). Add `jackett = ../../services/jackett.nix;` to `plugins/services/registry.nix`.

- [ ] **Step 4: Run focused checks and confirm success**

Run:

```bash
nix build -L .#checks.x86_64-linux.{service-settings,caddy-audit,authentik-catalogue}
```

Expected: all three checks build; the generated Authentik provider/application and Caddy vhost include Jackett and enforce the admin group.

- [ ] **Step 5: Commit**

```bash
git add services/jackett.nix plugins/services/registry.nix tests/caddy-audit.nix tests/authentik-catalogue.nix
git add -p tests/service-settings.nix
git commit -m "feat: add admin-only Jackett service"
```

### Task 2: Configure qBittorrent’s Jackett API plugin safely

**Files:**
- Modify: `services/jackett.nix`
- Modify: `services/qbittorrent.nix`
- Modify: `tests/qbittorrent-userns.nix`
- Modify: `tests/service-settings.nix`

**Interfaces:**
- Consumes: Jackett’s runtime `/var/lib/jackett/.config/Jackett/ServerConfig.json`, qBittorrent’s persistent `/var/lib/qbittorrent` tree, and `systemd.services.jackett`.
- Produces: `jackett-qbittorrent-plugin.service`, a one-shot unit that writes `/var/lib/qbittorrent/qBittorrent/nova3/engines/jackett.json`; `podman-qbittorrent.service` ordering on that initializer.

- [ ] **Step 1: Write failing assertions for initialization and ordering**

In `tests/service-settings.nix`, add:

```nix
pluginUnit = base.systemd.services.jackett-qbittorrent-plugin;
qbtUnit = base.systemd.services.podman-qbittorrent;
```

Add assertions that the plugin unit is gated, waits for Jackett, and writes the expected local API URL:

```nix
(expect "jackett: qBittorrent plugin is initialized from the generated local API key" (
  lib.elem "workload-online.target" pluginUnit.wantedBy
  && lib.elem "jackett.service" pluginUnit.after
  && lib.elem "jackett.service" pluginUnit.requires
  && lib.hasInfix "ServerConfig.json" pluginUnit.script
  && lib.hasInfix "http://127.0.0.1:9117" pluginUnit.script
  && lib.hasInfix "jackett.json" pluginUnit.script
  && lib.elem "jackett-qbittorrent-plugin.service" qbtUnit.requires
  && lib.elem "jackett-qbittorrent-plugin.service" qbtUnit.after
))
```

In `tests/qbittorrent-userns.nix`, import `../services/jackett.nix` and add a check that the plugin file is installed with `qbt:qbt` ownership and `0600` permissions by the initializer script.

- [ ] **Step 2: Run focused checks and confirm failure**

Run:

```bash
nix build -L .#checks.x86_64-linux.{service-settings,qbittorrent-userns}
```

Expected: the new qBittorrent integration assertions fail because no initializer or dependency exists.

- [ ] **Step 3: Implement the initializer and dependency**

In `services/jackett.nix`, define `systemd.services.jackett-qbittorrent-plugin` as a one-shot service. It must:

1. Require and run after `jackett.service`.
2. Be listed in `lanbat.services.jackett.units`, so workload gating moves it under `workload-online.target`.
3. Read the JSON API key with `jq -r '.APIKey'` from `/var/lib/jackett/.config/Jackett/ServerConfig.json`.
4. Refuse to write a placeholder, empty, or `null` key.
5. Create the Nova3 engines directory, use `mktemp` in that directory, and atomically rename a JSON file containing:

```json
{"api_key":"<generated key>","url":"http://127.0.0.1:9117","tracker_first":false,"thread_count":20}
```

6. Set the final file to owner/group `qbt:qbt` and mode `0600`.

Use Nix-escaped JSON generation (`jq --arg`) rather than shell interpolation for the API key. Give the service root privileges only for the cross-service file write; do not log the key.

In `services/qbittorrent.nix`, add both:

```nix
requires = [ "jackett-qbittorrent-plugin.service" ];
after = [ "jackett-qbittorrent-plugin.service" ];
```

to `systemd.services.podman-qbittorrent`, preserving its existing restart configuration.

- [ ] **Step 4: Run focused checks and confirm success**

Run:

```bash
nix build -L .#checks.x86_64-linux.{service-settings,qbittorrent-userns}
```

Expected: both checks build; the generated service graph prevents qBittorrent from starting before the API configuration is present.

- [ ] **Step 5: Commit**

```bash
git add services/jackett.nix services/qbittorrent.nix tests/qbittorrent-userns.nix
git add -p tests/service-settings.nix
git commit -m "feat: configure qBittorrent Jackett API"
```

### Task 3: Document deployment, operation, and recovery

**Files:**
- Modify: `docs/architecture.md`
- Modify: `docs/secure-layers.md`
- Modify: `docs/storage-layout.md`
- Modify: `docs/backup.md`
- Modify: `docs/failure-modes.md`
- Modify: `docs/operations.md`
- Modify: `docs/deployment-checklist.md`

**Interfaces:**
- Consumes: the deployed hostname, workload state path, Caddy/AuthentiK policy, and generated qBittorrent plugin configuration from Tasks 1–2.
- Produces: accurate administrator instructions without recording API keys or private-indexer credentials.

- [ ] **Step 1: Add the architecture and security documentation**

Add Jackett to the architecture service/auth matrix and hostname map as an admin-only, forward-auth-protected indexer manager. Add it to the workload-layer tables and explain that `/var/lib/jackett` contains indexer credentials and the API key, while TCP 9117 is local-only and the public UI passes through Caddy/AuthentiK.

- [ ] **Step 2: Add storage, backup, and recovery documentation**

Document `/var/lib/jackett` as workload-tier state in the storage layout and add it to the server backup inventory. In failure modes, state that Jackett and qBittorrent pause while the workload layer is locked and that qBittorrent’s plugin config is recreated from Jackett’s current API key at the next workload activation.

- [ ] **Step 3: Add the administrator runbook steps**

In `docs/operations.md` and `docs/deployment-checklist.md`, document:

```text
1. Unlock the workload layer.
2. Sign in to https://jackett.<domain> using an Authentik-admin account.
3. Add and test only indexers the administrator is authorized to use.
4. Search from VueTorrent/qBittorrent; do not copy the API key manually.
```

Explicitly note that Jackett has no reader/non-admin role and that the generated qBittorrent plugin file replaces any hand-edited key.

- [ ] **Step 4: Verify documentation references**

Run:

```bash
rg -n "Jackett|jackett" docs services tests
nix fmt -- docs services tests
git diff --check
```

Expected: all referenced paths, hostname, policy, and lifecycle statements agree with Tasks 1–2; formatting and whitespace checks pass.

- [ ] **Step 5: Commit**

```bash
git add docs/architecture.md docs/secure-layers.md docs/storage-layout.md docs/backup.md docs/failure-modes.md docs/deployment-checklist.md
git add -p docs/operations.md
git commit -m "docs: document Jackett operations"
```

### Task 4: Evaluate the complete deployment and perform deployment handoff

**Files:**
- Verify: `services/jackett.nix`
- Verify: `services/qbittorrent.nix`
- Verify: `tests/service-settings.nix`
- Verify: `tests/caddy-audit.nix`
- Verify: `tests/authentik-catalogue.nix`
- Verify: `tests/qbittorrent-userns.nix`

**Interfaces:**
- Consumes: all implementation and test changes from Tasks 1–3.
- Produces: evaluated NixOS configurations and a safe post-deployment setup sequence.

- [ ] **Step 1: Run the full targeted evaluation suite**

Run:

```bash
nix build -L .#checks.x86_64-linux.{service-settings,caddy-audit,authentik-catalogue,qbittorrent-userns,settings-guard,validate-deploy,load-deployments}
nix eval --raw .#nixosConfigurations.example-server.config.system.build.toplevel.drvPath
```

Expected: every check and the example server evaluation succeed.

- [ ] **Step 2: Run the project formatting and diff checks**

Run:

```bash
nix fmt
git diff --check
git status --short
```

Expected: formatter leaves valid Nix; no whitespace errors; the status identifies only intended new changes plus pre-existing user changes.

- [ ] **Step 3: Perform real-host setup after deployment**

On the deployed server, run:

```bash
sudo unlock-workload
systemctl status jackett jackett-qbittorrent-plugin podman-qbittorrent
curl -fsS http://127.0.0.1:9117/UI/Dashboard >/dev/null
```

Then authenticate to `https://jackett.<domain>`, add authorized indexers, test them in Jackett, and run a qBittorrent search. Do not disclose the API key or expose port 9117.

- [ ] **Step 4: Commit only formatter changes belonging to this feature**

```bash
git status --short
git add -p services/jackett.nix services/qbittorrent.nix tests/service-settings.nix tests/caddy-audit.nix tests/authentik-catalogue.nix tests/qbittorrent-userns.nix
git commit -m "style: format Jackett integration"
```
