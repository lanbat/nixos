# Module Layout by Role and Board: Storage Migration Plan

> **Status:** carried out in the working tree (uncommitted) on 2026-10-03, with the
> decisions below. Steps 1-5 are done; only committing remains, which should wait until
> the branches under "Risks" are checked.

**Goal:** Put each Raspberry Pi module where the thing that owns it lives: board
specifics under `hosts/<board>/`, a role's own modules under `modules/<role>/`, and
only what several Pi roles share under `modules/pi/`. This plan covers the storage Pi's
modules; the board half (`hosts/pi3`, `hosts/pi5`, `lib/platforms.nix`) is already in
place.

**Not a data migration.** The LUKS mapper names (`storage-<d>`), mount points
(`/mnt/storage-<d>`), NFS exports (`/srv/storage/<d>`), unit names and drive keys stay as
they are. Only the paths of the Nix source files change, so the drives, their contents
and the Clevis/Tang bindings are untouched and a deploy of the moved code is a no-op
switch. If "storage" meant moving the data on the drives, or the Pi's boot storage
(SD to NVMe), that is a different plan; say so.

## What is where now

`modules/pi/` holds nine modules that belong to three different owners:

| Module | Used by | Belongs in |
|---|---|---|
| `clevis-unlock.nix`, `nfs-exports.nix`, `storage.nix`, `user-quotas.nix` | the `storage-pi` role only (`lib/roles.nix`) | `modules/storage/` |
| `tv.nix` | the `tv` plugin only, which is for the `storage-pi` role (`plugins/tv/default.nix`) | `modules/storage/tv-box.nix` |
| `audio.nix`, `snapclient.nix`, `speakers.nix`, `telegraf.nix` | more than one Pi role (`storage-pi`, `voice-pi`) or the voice plugin | stays in `modules/pi/` |

`modules/server/` already follows this: the server role's own modules sit under
`modules/server/`. The storage role is the odd one out.

Nothing in the four storage modules is specific to one board. They take the drive list
from `hosts.<key>.storage.drives` (by-id names) and use no PCIe, USB or firmware option, so
they work the same on a Pi 4 with USB disks. What does depend on the board (enabling the
NVMe HAT's PCIe link, firmware, boot order) belongs in that board's
`hosts/<board>/hardware.nix` and today is only the Pi 5's. If a Pi 4 storage host needs
something, it goes in `hosts/pi4/hardware.nix`, not in these modules.

Pi 5 specifics still outside `hosts/pi5/`, to be moved or labelled as part of this work:

- `modules/pi/tv.nix`: the emulator list is chosen for what "runs well on a Raspberry Pi 5".
  Move with the file into `plugins/tv/` and say in its header that it is tuned for the Pi 5.
- `docs/deployment-checklist.md`, Phase 2: flashing and the first switch are the Pi 5's
  (nixos-raspberrypi installer image). Retitle it "Pi 5" and add the Pi 3 pointer to
  `docs/pi3-satellite.md`.
- `modules/pi/clevis-unlock.nix` line 68: a comment about the Pi 5 having no TPM. Fine as
  a comment; keep it.
- Fixture and test host names (`pi5`, `tests/pi.nix`): they are the storage-pi test
  fixture, which uses the Pi 5 platform. Rename `tests/pi.nix` to `tests/storage-pi.nix`
  (so `tests/voice-pi.nix` has a sibling of the same kind) in the same step.

## Target layout

```
hosts/pi3/hardware.nix            Pi 3 board
hosts/pi5/hardware.nix            Pi 5 board
hosts/pi4/hardware.nix            (later) Pi 4 board, one entry in lib/platforms.nix
lib/platforms.nix                 the table of boards
lib/roles.nix                     the table of roles
modules/pi/                       audio, snapclient, speakers, telegraf (shared by Pi roles)
modules/storage/                  clevis-unlock, nfs-exports, storage, user-quotas, tv-box
plugins/tv/default.nix            the plugin, which names modules/storage/tv-box.nix
```

The names the roles bundle them under (`clevis-unlock`, `nfs-exports`, `storage`,
`user-quotas`) do not change, so a deploy entry's `roleModules.storage = ./mine.nix`
keeps working. No shim is left at the old paths: they are internal paths, only the
bundle names are an interface.

## Steps

Each step is one commit, and the evaluation check after it must pass before the next.

1. **Pure move, no edits.** `git mv modules/pi/{clevis-unlock,nfs-exports,storage,user-quotas}.nix modules/storage/`
   and `git mv modules/pi/tv.nix modules/storage/tv-box.nix`. A commit that only renames keeps
   Git's rename detection exact, so branches that touch these files still merge.
2. **Point the code at the new paths.**
   - `lib/roles.nix` lines 60-63: the four `storage-pi` bundles.
   - `plugins/tv/default.nix`: `../../modules/pi/tv.nix` becomes
     `../../modules/storage/tv-box.nix`.
   - Relative imports inside the moved files (`../../lib/...`): `modules/storage/` is at
     the same depth as `modules/pi/`, so they stay. Check by evaluating, not by eye.
3. **Fix the path mentions** in comments and docs (`grep -rn 'modules/pi/'` lists them):
   `services/{romm,samba,audiobookshelf,qbittorrent}.nix` (all say `modules/pi/storage.nix`),
   `hosts/pi5/hardware.nix` (`clevis-unlock`), `lib/roles/storage-pi.nix` and
   `lib/nfs-clients.nix` (`nfs-exports`), `pkgs/es-de/default.nix` (`tv.nix`),
   `docs/storage-layout.md` (the table at lines 51-54 and line 65), and the moved
   files' own headers.
4. **Rename the test** `tests/pi.nix` to `tests/storage-pi.nix`, as tests are named for
   their role (`tests/server.nix`, `tests/voice-pi.nix`): its entry in `flake.nix`
   (`checks.aarch64-linux.pi` becomes `storage-pi`), the test, node and driver names, and
   the commands in `CONTRIBUTING.md`. CI lists the aarch64 checks by evaluating them, so
   `check.yml` needs no edit.
   `flake.nix` and `check.yml` have uncommitted edits from other work, so edit only those
   lines.
5. **Docs.** `CONTRIBUTING.md` ("How the repository fits together"): add the
   `modules/<role>/` rule, "a role's own modules in `modules/<role>/`, what several Pi
   roles share in `modules/pi/`", next to the existing `hosts/` line.

## Verification

- `nix eval --raw path:.#nixosConfigurations.<profile>-pi-storage.config.system.build.toplevel.drvPath`
  before step 1 and after each step. It must not change: the move changes where source
  files live, not what they define, and the earlier `hosts/pi` to `hosts/pi5` rename
  left it identical. A changed path means a step edited behaviour.
- The same for the server and the Pi 3 hosts, and for `example-*` from a checkout with no
  `deploy.nix`.
- `nix build path:.#checks.x86_64-linux.{load-deployments,validate-deploy,plugins,storage-drives}`
  and the evaluation of `checks.aarch64-linux.{pi,voice-pi}.driver` (renamed in step 4).
- `grep -rn 'modules/pi/' .` lists only the four shared modules.

## Risks and how they are handled

- **Branches and worktrees that edit these files.** There are about 40 worktrees under
  `../`. `git cherry master <branch>` still lists some as unmerged
  (`feat/storage-drives`, `refactor/shared-role-base`, `fix/rootless-storage-ownership`),
  but the repository squash-merges, so that does not prove they are unmerged. Before step 1,
  check each against master with `git diff master <branch> -- modules/pi lib/roles.nix`; if
  one is still live, land it first or rebase it after the move. Step 1 being a pure
  rename keeps either order cheap.
- **Uncommitted work in this checkout.** Files with other people's edits (`flake.nix`,
  `check.yml`, `docs/deployment-checklist.md`, `docs/storage-layout.md`,
  `services/home-assistant.nix`) are touched only on the lines named above, and the
  commits are staged by hunk (`git add -p`), as the Jackett plan does.
- **A deploy to the real storage Pi.** Because the derivation does not change, nothing
  restarts and the drives are not re-unlocked. Verify with `nix store diff-closures`
  between the running system and the new one before `deploy`; it should print nothing.
- **Outside users.** The published repository may be imported by paths. State the move in
  the pull request, and in the release notes if there are any; the bundle names are the
  stable interface.

## Decisions (confirmed)

1. The directory is `modules/storage/`, not `modules/storage-pi/`. The role keeps its name
   `storage-pi`; renaming roles is a breaking change for deploy files and would be its own
   plan with a deprecation alias.
2. `tv.nix` becomes `modules/storage/tv-box.nix`. The repo's convention is that a
   plugin names a module under `modules/<role>/` (the `android` plugin uses
   `modules/server/android-devices.nix`), not a file inside the plugin's own directory, and
   the `tv` plugin is for the `storage-pi` role. The file is named for the appliance it
   makes, a TV box, which matches the plugin (`lanbat-tv`) and its `tv-*` units. "Raspberry
   Pi based" is said in the header and the plugin description, not the filename, because
   nothing in the code needs Pi hardware; only the emulator list is tuned for the Pi 5
   and is labelled so. If the TV box ever runs on a host without storage drives, it moves to
   its own `modules/tv/`.
3. The test is renamed `tests/storage-pi.nix`, following `tests/voice-pi.nix`.
