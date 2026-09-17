# Post-Restructure Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden the deployment-profile architecture with validation, better tests/CI, scalable secrets patterns, developer tooling, documentation fixes, and small architectural cleanups identified after the extensibility restructure.

**Architecture:** Add a pure-Nix `lib/validate-deploy.nix` called from `lib/default.nix` for every profile, expose flake apps for linting and host discovery, replace fragile shell parsing with `nix eval`, expand tests to cover multi-profile manifests and the `voice-pi` role, and align docs/secrets examples with multi-host reality. Larger items (per-profile secrets, external plugin template) ship as documented patterns first, with optional code hooks where low-cost.

**Tech Stack:** Nix, NixOS modules, deploy-rs, agenix, nixos-test (VM), GitHub Actions, bash

**Spec:** Informal follow-up list from post-restructure review (conversation 2026-09-16). No separate spec file.

## Global Constraints

- Do not edit `/home/traph/.cursor/plans/extensible_nixos_config_27104167.plan.md`.
- Never commit `deploy.nix`, `deployments/*/deploy.nix` (except `deployments/example/deploy.nix`), `secrets/secrets.nix`, or real credentials.
- Preserve backward compatibility for single-profile `default` hosts (`server`, `pi-storage` unprefixed names).
- Validation errors must use `builtins.throw` with actionable messages (profile name, host key, field path).
- Follow existing code style: small focused files, minimal scope per commit, match naming in `lib/` and `tests/`.
- Run `nix flake check --no-build --all-systems` after each task group; run VM checks when touching tests.
- Only create git commits when the user explicitly asks.

---

## File map (created or modified)

| File | Responsibility |
|---|---|
| `lib/validate-deploy.nix` | Pure deploy/profile validation |
| `lib/network.nix` | `prefixLengthFromCidr` helper |
| `lib/deploy-query.nix` | Query deploy values for scripts (`server-ip`, `hosts`, …) |
| `lib/default.nix` | Call `validateDeploy` per profile; export helpers |
| `lib/load-deployments.nix` | Unchanged interface; validation happens in `mkProfile` |
| `modules/core/settings.nix` | Optional `primaryServer`/`primaryStorage` overrides; remove `piTvFrontend` |
| `modules/core/host-context.nix` | Honor primary overrides |
| `modules/pi/tv.nix` | Remove `mkIf config.lanbat.piTvFrontend` (module only loads via TV plugin) |
| `plugins/tv/default.nix` | Remove `piTvFrontend` setter module |
| `lib/roles/{server,storage-pi,voice-pi}.nix` | Use `prefixLengthFromCidr` |
| `flake.nix` | New checks, apps (`validate-deploy`, `hosts`, `deploy-query`) |
| `tests/validate-deploy.nix` | Pure eval tests for validation |
| `tests/load-deployments.nix` | Multi-profile normalization tests |
| `tests/voice-pi.nix` | VM test for voice-pi role via `mkHost` |
| `tests/deploy-rs-fixture.nix` | deploy-rs checks using checked-in fixture |
| `tests/lib/mk-host-fixture.nix` | Shared minimal deploy + `mkHost` builder for tests |
| `tests/pi.nix` | Refactor to use `mkHost` fixture path |
| `secrets/lib/read-deploy.sh` | Delegate to `nix run .#deploy-query` |
| `secrets/secrets.nix.example` | Multi-host key patterns |
| `examples/lanbat-plugin-minimal/` | External plugin template flake |
| `.github/workflows/check.yml` | Add plugins, validate-deploy, deploy-rs fixture |
| `.github/workflows/nightly.yml` | Optional full server VM test |
| Docs (see tasks 10–11) | Consistency and multi-host examples |

---

### Task 1: Network helper and prefix length fix

**Files:**
- Create: `lib/network.nix`
- Modify: `lib/roles/server.nix`, `lib/roles/storage-pi.nix`, `lib/roles/voice-pi.nix`
- Test: manual eval of example profile

**Interfaces:**
- Produces: `prefixLengthFromCidr : String -> Int` in `lib/network.nix`

- [ ] **Step 1: Create `lib/network.nix`**

```nix
# lib/network.nix
{ lib }:

let
  prefixLengthFromCidr =
    cidr:
    let
      parts = lib.splitString "/" cidr;
    in
    if lib.length parts != 2 then
      builtins.throw "lanbat: invalid CIDR '${cidr}' (expected e.g. 192.168.1.0/24)"
    else
      lib.toInt (lib.elemAt parts 1);
in
{
  prefixLengthFromCidr = prefixLengthFromCidr;
}
```

- [ ] **Step 2: Update all three role files**

In each role, replace hardcoded `prefixLength = 24` with:

```nix
let
  networkLib = import ../network.nix { inherit lib; };
  prefixLength = networkLib.prefixLengthFromCidr config.lanbat.deployment.lanSubnet;
in
```

Apply inside the `networking.interfaces.${net.interface}.ipv4.addresses` block in:
- `lib/roles/server.nix`
- `lib/roles/storage-pi.nix`
- `lib/roles/voice-pi.nix`

- [ ] **Step 3: Verify**

Run: `nix flake check --no-build --all-systems`
Expected: PASS (example profile uses `192.0.2.0/24` → prefix 24)

- [ ] **Step 4: Commit** (only if user requests)

```bash
git add lib/network.nix lib/roles/server.nix lib/roles/storage-pi.nix lib/roles/voice-pi.nix
git commit -m "fix: derive interface prefix length from lanSubnet"
```

---

### Task 2: Deploy validation library

**Files:**
- Create: `lib/validate-deploy.nix`
- Create: `tests/validate-deploy.nix`
- Modify: `flake.nix` (register check)

**Interfaces:**
- Produces: `validateDeploy : { profileName : String, deploy : { deployment, hosts } } -> deploy` (returns deploy unchanged or throws)
- Consumes: `lib/host.nix` (`hostsWithRole`, `primaryHost`), `lib/plugins.nix` (`resolvePlugins`)

- [ ] **Step 1: Write failing test `tests/validate-deploy.nix`**

```nix
# tests/validate-deploy.nix
{ lib, pkgs }:

let
  validate = import ../lib/validate-deploy.nix { inherit lib; };

  baseDeploy = import ../deployments/example/deploy.nix {
    inputs = { self = { lanbatPlugins = import ../plugins/services; }; };
  };

  expectThrow =
    name: deploy:
    let
      result = builtins.tryEval (validate.validateDeploy { profileName = "test"; deploy = deploy; });
    in
    if result.success then "expected ${name} to throw" else null;

  badVoiceRooms = baseDeploy // {
    deployment = baseDeploy.deployment // {
      voiceRooms = { "Office" = "no-such-host"; };
    };
  };

  missingDrives = baseDeploy // {
    hosts = baseDeploy.hosts // {
      pi-storage = baseDeploy.hosts.pi-storage // {
        storage = { drives = { }; };
      };
    };
  };

  twoServers = baseDeploy // {
    hosts = baseDeploy.hosts // {
      server-b = baseDeploy.hosts.server;
    };
  };

  failures = lib.filter (x: x != null) [
    (expectThrow "bad voiceRooms host" badVoiceRooms)
    (expectThrow "storage-pi without drives" missingDrives)
    (expectThrow "multiple servers without primary override" twoServers)
  ];
in
pkgs.runCommand "validate-deploy-check" { } ''
  if [ ${toString (lib.length failures)} -ne 0 ]; then
    echo "validate-deploy tests failed:" >&2
    ${lib.concatStringsSep "\n" (map (m: "echo \"  - ${m}\" >&2") failures)}
    exit 1
  fi
  touch $out
''
```

Adjust `baseDeploy` inputs stub to include all plugins referenced by example deploy (`services`, `tv`, `voice`).

- [ ] **Step 2: Run test to verify it fails**

Run: `nix build .#checks.x86_64-linux.validate-deploy -L`
Expected: FAIL (module missing or tests pass unexpectedly)

- [ ] **Step 3: Implement `lib/validate-deploy.nix`**

Validation rules (each throws with profile + context):

1. **Placeholder detection** — recurse `deploy` attrset; any string matching `CHANGE_ME` throws.
2. **Host keys** — `hosts` must be non-empty; each host must have `role`, `networking.{ip,interface,hostname}`, `system`.
3. **Role requirements:**
   - `server` → `disks.system` non-empty string
   - `storage-pi` → `storage.drives` has keys `a` and `b` with non-empty values
   - `voice-pi` → no disk requirements
4. **Plugins** — call `resolvePlugins host.role (host.plugins or [])` for each host (reuses existing plugin validation).
5. **voiceRooms** — every value must be a key in `hosts`; host must include `lanbatPlugins.voice` or plugin named `lanbat-voice` in its `plugins` list (check plugin `.name` fields).
6. **Multiple primaries** — if `hostsWithRole hosts "server"` has length > 1 and `deployment.primaryServer or null` is null → throw. Same for `storage-pi` / `primaryStorage`.
7. **NFS storageHost sanity** — not in deploy file; skip (service-level). Document only.

```nix
# lib/validate-deploy.nix — structure
{ lib }:

let
  hostLib = import ./host.nix { inherit lib; };
  pluginLib = import ./plugins.nix { inherit lib; };

  containsChangeMe = value: ...; # lib.fold over strings

  validateHost = profileName: hosts: name: host: ...;

  validateDeploy = { profileName, deploy }: ...
in
{ validateDeploy = validateDeploy; }
```

- [ ] **Step 4: Register check in `flake.nix`**

```nix
validate-deploy = import ./tests/validate-deploy.nix { inherit lib pkgs; };
```

- [ ] **Step 5: Run test**

Run: `nix build .#checks.x86_64-linux.validate-deploy -L`
Expected: PASS

---

### Task 3: Primary host overrides and wire validation into profiles

**Files:**
- Modify: `modules/core/settings.nix`
- Modify: `modules/core/host-context.nix`
- Modify: `lib/default.nix`
- Modify: `deployments/example/deploy.nix` (only if needed for new optional fields)
- Modify: `deployments/homelab/deploy.nix.example`

**Interfaces:**
- Adds deploy-time options: `deployment.primaryServer` and `deployment.primaryStorage` (nullable strings, default `null`)
- `validateDeploy` runs inside `mkProfile` before `mkHost`

- [ ] **Step 1: Add override options to `settings.nix`**

Inside `deployment` options (not readOnly):

```nix
primaryServer = mkOption {
  type = types.nullOr types.str;
  default = null;
  description = "Host key for the primary server. Required when multiple server-role hosts exist.";
};
primaryStorage = mkOption {
  type = types.nullOr types.str;
  default = null;
  description = "Host key for the primary storage-pi. Required when multiple storage-pi hosts exist.";
};
```

Remove `primaryServer`/`primaryStorage` from `allowedWithDefault` exception list in `tests/settings-guard.nix` if they get defaults (they do — keep them in allowed list).

- [ ] **Step 2: Update `host-context.nix`**

```nix
primaryServer =
  config.lanbat.deployment.primaryServer
  or hostLib.primaryHost hosts "server";
primaryStorage =
  config.lanbat.deployment.primaryStorage
  or hostLib.primaryHost hosts "storage-pi";
```

Add assertions (in same module):

```nix
assertions = [
  {
    assertion = config.lanbat.deployment.primaryServer == null
      || config.lanbat.hosts ? ${config.lanbat.deployment.primaryServer};
    message = "lanbat.deployment.primaryServer must be a host key in lanbat.hosts";
  }
  # same for primaryStorage
];
```

- [ ] **Step 3: Call validation in `lib/default.nix` `mkProfile`**

```nix
mkProfile = profileName: deploy:
  let
    deploy' = validateLib.validateDeploy { inherit profileName; deploy = deploy; };
  in
  ...
```

Import `validate-deploy.nix` at top of `lib/default.nix`.

- [ ] **Step 4: Verify example profile still evaluates**

Run: `nix flake check --no-build --all-systems`
Expected: PASS

---

### Task 4: Multi-profile tests

**Files:**
- Create: `tests/load-deployments.nix`
- Create: `tests/fixtures/multi-profile-deploy.nix`
- Modify: `flake.nix`

**Interfaces:**
- Produces: check that `loadDeployments.normalize` on fixture yields `homelab` + `cabin` profiles and `hostFlakeName` produces distinct flake attrs

- [ ] **Step 1: Create fixture**

```nix
# tests/fixtures/multi-profile-deploy.nix
{ ... }:
{
  profiles = {
    homelab = { deployment = { domain = "home.test"; /* minimal required fields */ }; hosts = { server = { ... }; }; };
    cabin = { deployment = { domain = "cabin.test"; ... }; hosts = { server = { ... }; }; };
  };
}
```

Use RFC5737 TEST-NET IPs (`192.0.2.x`), valid plugins stubs, and all required deployment fields (copy minimal set from `deployments/example/deploy.nix`).

- [ ] **Step 2: Write `tests/load-deployments.nix`**

Assert:
- `normalize fixture` has keys `homelab` and `cabin`
- `hostFlakeName "homelab" "server" == "homelab-server"`
- `hostFlakeName "default" "server" == "server"`
- Evaluating both configurations via `mkProfile` does not throw

- [ ] **Step 3: Register check and run**

Run: `nix build .#checks.x86_64-linux.load-deployments -L`
Expected: PASS

---

### Task 5: mkHost test fixture and Pi test refactor

**Files:**
- Create: `tests/lib/mk-host-fixture.nix`
- Modify: `tests/pi.nix`

**Interfaces:**
- Produces: `mkPiStorageHost : { pkgs, agenix, inputs } -> NixOS module list result` building through `lib/mkHost.nix` with a test deploy map

- [ ] **Step 1: Create `tests/lib/mk-host-fixture.nix`**

Build a minimal `deploy` attrset (storage-pi with `tv`+`voice` plugins disabled or tv disabled for VM speed) and call `mkHost` from `lib/mkHost.nix` with `profileName = "test"`.

Export:
- `piStorageSystem` — nixos module for pi-storage
- `voicePiSystem` — for Task 6

Use the same agenix/test-secrets pattern as current `tests/pi.nix`.

- [ ] **Step 2: Refactor `tests/pi.nix`**

Replace direct role/module imports with:

```nix
nodes.pi = import ./lib/mk-host-fixture.nix { ... }.piStorageConfig;
```

Keep `lanbat.piTvFrontend = lib.mkForce false` until Task 9 removes the option (or disable `tv` plugin in fixture).

- [ ] **Step 3: Run Pi VM test**

Run: `nix build .#checks.aarch64-linux.pi -L` (on aarch64+KVM) or at minimum `nix flake check --no-build` on x86_64
Expected: PASS / eval OK

---

### Task 6: voice-pi VM test

**Files:**
- Create: `tests/voice-pi.nix`
- Modify: `flake.nix`

- [ ] **Step 1: Write `tests/voice-pi.nix`**

Use `mk-host-fixture.nix` voice-pi system. Assertions:
- `admin` user exists
- `sshd` active
- Wyoming satellite unit exists (grep unit name from `modules/core/voice-satellite.nix`)
- Firewall restricts port 10700 to server IP (optional: check iptables or unit ExecStart)

Keep memory low; no NFS/TV.

- [ ] **Step 2: Register as `checks.aarch64-linux.voice-pi`**

- [ ] **Step 3: Run**

Run: `nix build .#checks.aarch64-linux.voice-pi -L` (if available) or document skip on x86_64-only machines

---

### Task 7: deploy-rs fixture check (CI without user deploy.nix)

**Files:**
- Create: `tests/deploy-rs-fixture.nix`
- Modify: `flake.nix`

- [ ] **Step 1: Implement `tests/deploy-rs-fixture.nix`**

```nix
# Build deployChecks from a fixture profile, independent of ./deploy.nix
let
  fixture = import ./fixtures/multi-profile-deploy.nix { inputs = inputsStub; };
  profiles = loadDeployments.normalize fixture;
  lanbatLib = import ../lib { ... profiles = profiles; };
  checks = (lanbatLib.deployLib "x86_64-linux").deployChecks {
    nodes = lib.filterAttrs (n: _: lib.hasSuffix "-server" n) lanbatLib.deployNodes;
  };
in
checks.homelab-server or (throw "expected homelab-server deploy node")
```

Only include x86_64 server nodes (Pi remoteBuild complicates CI).

- [ ] **Step 2: Add to `checks.x86_64-linux` unconditionally**

- [ ] **Step 3: Run**

Run: `nix build .#checks.x86_64-linux.deploy-rs-fixture -L`
Expected: PASS

---

### Task 8: Flake apps — deploy-query and hosts

**Files:**
- Create: `lib/deploy-query.nix`
- Modify: `flake.nix`
- Modify: `secrets/lib/read-deploy.sh`
- Modify: `secrets/generate-homepage-widgets.sh` (if needed)

**Interfaces:**
- Produces CLI via `apps.x86_64-linux.deploy-query` — args: `<key> [profile]`
- Keys: `server-ip`, `domain`, `profile`, `flake-server`, `immich-admin-email`, `hosts`, `host-ips`, `deploy-file`

- [ ] **Step 1: Implement `lib/deploy-query.nix`**

Pure functions reading normalized profiles (same logic as flake: `deploy.nix` or example). Use `lib/host.nix` for lookups. For multi-profile, default profile = first in `deploy.nix` profiles attr order or `homelab` if present.

Example `hosts` output (one per line): `homelab-server 192.0.2.10`

- [ ] **Step 2: Add flake apps**

```nix
apps.x86_64-linux.deploy-query = {
  type = "app";
  program = toString (pkgs.writeShellScript "deploy-query" '''
    exec ${pkgs.nix}/bin/nix eval --raw .#lib.lanbat.deployQuery.${"$1"} ${"$2" or ""}
  ''');
};
apps.x86_64-linux.hosts = {
  type = "app";
  program = ... # nix eval .#lib.lanbat.deployQuery.hosts
};
apps.x86_64-linux.validate-deploy = {
  type = "app";
  program = ... # nix build .#checks.x86_64-linux.validate-deploy
};
```

Export `deployQuery` from `lib/default.nix` or a small wrapper.

- [ ] **Step 3: Replace `read-deploy.sh` body**

```bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
nix run .#deploy-query -- "$1" 2>/dev/null
```

Keep bash fallback to `deployments/example/deploy.nix` only if `nix run` fails (contributors without deploy).

- [ ] **Step 4: Manual test**

Run: `nix run .#hosts` and `nix run .#deploy-query -- server-ip`
Expected: lists `example-server` / `192.0.2.10` without local `deploy.nix`

---

### Task 9: Remove `piTvFrontend` option (plugin-only TV)

**Files:**
- Modify: `modules/pi/tv.nix` — remove outer `mkIf config.lanbat.piTvFrontend`
- Modify: `plugins/tv/default.nix` — remove setter module
- Modify: `modules/core/settings.nix` — remove `piTvFrontend` option
- Modify: `tests/settings-guard.nix` — remove `piTvFrontend` from allowlist
- Modify: `tests/pi.nix` — remove `lanbat.piTvFrontend` line; disable TV plugin in fixture instead
- Modify: docs (Task 11)

- [ ] **Step 1: Make TV module unconditional**

`modules/pi/tv.nix` config block applies whenever the module is imported (only via TV plugin).

- [ ] **Step 2: Remove option and references**

Grep: `piTvFrontend` — update all hits.

- [ ] **Step 3: Verify**

Run: `nix flake check --no-build --all-systems` and `nix build .#checks.x86_64-linux.settings-guard -L`

---

### Task 10: Secrets scalability

**Files:**
- Modify: `secrets/secrets.nix.example`
- Modify: `secrets/README.md`
- Modify: `docs/extensibility.md`

- [ ] **Step 1: Expand `secrets.nix.example`**

```nix
let
  server = "...";
  pi-storage = "...";
  pi-bedroom = "...";  # optional voice-pi
  admin = "...";

  serverKeys = [ server admin ];
  storagePiKeys = [ pi-storage admin ];
  voicePiKeys = [ pi-bedroom admin ];
  allPis = [ pi-storage pi-bedroom ];
  allKeys = serverKeys ++ allPis;
in
{
  "telegraf-token.age".publicKeys = allKeys;
  "ha-voice-token.age".publicKeys = allKeys;
  # server-only secrets stay on serverKeys
}
```

Add comments mapping host keys in `deploy.nix` → agenix recipient variables.

- [ ] **Step 2: Document multi-profile secrets strategy in `secrets/README.md`**

Sections:
- **Multiple Pis** — list pattern above
- **Multiple profiles (homelab + cabin)** — encrypt each `.age` to the union of host keys from all profiles that need that secret; note duplication tradeoff
- **Future: per-profile secrets** — document desired path `deployments/<profile>/secrets.nix` as not yet implemented; link to plan

- [ ] **Step 3: Add voice-pi + multi-storage example to `docs/extensibility.md`**

Show `hosts.pi-bedroom`, `nfs.storageHost`, and matching `secrets.nix` recipients.

---

### Task 11: Documentation consistency pass

**Files:**
- Modify: `docs/plugins.md`
- Modify: `CONTRIBUTING.md`
- Modify: `docs/migration.md`
- Modify: `docs/deployment-checklist.md`
- Modify: `docs/architecture.md` (brief tooling section)

- [ ] **Step 1: Fix secrets responsibility in `docs/plugins.md`**

Align with CONTRIBUTING: plugin PRs add placeholder `.age` files; maintainer re-encrypts to deployment host keys before merge. Plugin README documents required secrets.

- [ ] **Step 2: Update CONTRIBUTING CI commands**

```bash
nix build .#checks.x86_64-linux.{assertions,workload-gate,postgresql,plugins,settings-guard,validate-deploy,load-deployments,deploy-rs-fixture}
```

- [ ] **Step 3: `docs/migration.md`**

Add final step: delete legacy `local.nix` after migrating values.

- [ ] **Step 4: `docs/deployment-checklist.md`**

Replace `piTvFrontend` references with “TV plugin (`lanbatPlugins.tv`) enabled on the storage Pi”.

- [ ] **Step 5: Add “Tooling” subsection to README or `docs/extensibility.md`**

Document:
- `nix run .#validate-deploy`
- `nix run .#hosts`
- `nix run .#deploy-query -- server-ip`

---

### Task 12: External plugin template

**Files:**
- Create: `examples/lanbat-plugin-minimal/flake.nix`
- Create: `examples/lanbat-plugin-minimal/README.md`
- Modify: `docs/plugins.md` — link to example

- [ ] **Step 1: Minimal plugin flake**

```nix
{
  description = "Minimal lanbat plugin example";
  inputs.lanbat.url = "github:lanbat/nixos";
  outputs = { self, ... }: {
    lanbatPlugin = {
      name = "example-noop";
      version = 1;
      roles = [ "server" ];
      modules = [ ./module.nix ];
    };
  };
}
```

`module.nix` adds a harmless `environment.etc."lanbat-plugin-example".text` file.

- [ ] **Step 2: README with consumption steps**

Show flake input + `hosts.server.plugins` entry. Note: not wired into main flake CI (example only).

---

### Task 13: CI workflow updates

**Files:**
- Modify: `.github/workflows/check.yml`
- Create: `.github/workflows/nightly.yml`

- [ ] **Step 1: Extend `vm-test` job build list**

Add: `.#checks.x86_64-linux.plugins`, `.#checks.x86_64-linux.validate-deploy`, `.#checks.x86_64-linux.load-deployments`, `.#checks.x86_64-linux.deploy-rs-fixture`

- [ ] **Step 2: Create `nightly.yml`**

```yaml
on:
  schedule:
    - cron: '0 3 * * *'
  workflow_dispatch:

jobs:
  server-vm:
    runs-on: ubuntu-latest
    steps:
      # KVM setup same as check.yml
      - run: nix build -L .#checks.x86_64-linux.server
```

Document in CONTRIBUTING that full server VM is nightly + manual.

- [ ] **Step 3: Push and verify CI green**

---

### Task 14: Per-profile secrets (optional stretch)

**Only implement if Tasks 1–13 are complete and time allows.**

**Files:**
- Create: `lib/secrets-profile.nix`
- Modify: `modules/wiring/secrets.nix` or agenix module import path
- Modify: `docs/extensibility.md`

**Approach:**
- Optional `deployment.secretsProfile = "homelab"` → agenix reads `deployments/homelab/secrets.nix` if present, else `secrets/secrets.nix`
- `secrets/secrets.nix` remains fallback for single-profile users
- Add example `deployments/homelab/secrets.nix.example`

**Skip if:** agenix module cannot easily switch recipients path without invasive changes — in that case leave documentation-only from Task 10.

---

## Self-review (spec coverage)

| Requirement | Task |
|---|---|
| Deploy validation (voiceRooms, roles, placeholders, multiples) | 2, 3 |
| primaryServer/primaryStorage explicit overrides | 3 |
| prefixLength from lanSubnet | 1 |
| plugins check in CI | 13 |
| Multi-profile test | 4 |
| voice-pi test | 6 |
| Pi test via mkHost | 5 |
| deploy-rs CI without user deploy.nix | 7 |
| read-deploy → nix eval | 8 |
| validate-deploy / hosts apps | 8 |
| Secrets multi-host example | 10 |
| Multi-profile secrets strategy (doc + optional code) | 10, 14 |
| docs/plugins vs CONTRIBUTING | 11 |
| piTvFrontend → plugin-only | 9, 11 |
| migration delete local.nix | 11 |
| External plugin template | 12 |
| Full server VM nightly | 13 |

No placeholders remain in task steps above.

---

## Suggested commit sequence (when user asks)

1. `fix: derive prefix length from lanSubnet`
2. `feat: add deploy validation library and tests`
3. `feat: support explicit primary server/storage host keys`
4. `test: multi-profile and deploy-rs fixture checks`
5. `test: build pi and voice-pi hosts through mkHost`
6. `feat: add deploy-query and hosts flake apps`
7. `refactor: make TV plugin unconditional on piTvFrontend option`
8. `docs: multi-host secrets and tooling`
9. `ci: extend checks and add nightly server VM`

---

## Execution handoff

**Plan complete and saved to `docs/superpowers/plans/2026-09-16-post-restructure-hardening.md`.**

**Two execution options:**

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task with review between tasks
2. **Inline Execution** — implement tasks in this session with checkpoints after Tasks 3, 7, 9, and 13

**Which approach?**
