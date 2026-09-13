"""Build browser-ready arcade romsets for RomM's player.

The arcade cores of RomM's browser emulator (EmulatorJS) can't read 7z, and a
game that needs a BIOS finds it only inside its own archive. The library keeps
MAME's 7z sets, which qBittorrent seeds and the TV reads, so this builds a zip
copy of each: the set's files plus those of the parent and BIOS sets it needs,
according to FinalBurn Neo's arcade DAT. BIOS-only sets go into the games that
need them rather than getting a zip of their own.

A zip is rebuilt when one of its sets changes, and removed when its set goes.
"""

import os
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

SOURCE = Path(os.environ["SOURCE_DIR"])
TARGET = Path(os.environ["TARGET_DIR"])
DAT = os.environ["FBNEO_DAT"]
SEVENZIP = os.environ.get("SEVENZIP", "7z")


def log(message):
    print(f"romm-browser-romsets: {message}", flush=True)


def load_dat():
    games = {}
    for _, element in ET.iterparse(DAT):
        if element.tag == "game":
            games[element.get("name")] = {
                "romof": element.get("romof"),
                "isbios": element.get("isbios") == "yes",
            }
            element.clear()
    return games


def needed_sets(name, games):
    """The parent and BIOS sets a game loads files from, nearest first."""
    sets, game = [], games.get(name)
    while game and game["romof"] and game["romof"] not in sets:
        sets.append(game["romof"])
        game = games.get(game["romof"])
    return sets


def build(archives, target):
    with tempfile.TemporaryDirectory() as tmp:
        # The game's own set last, so its files win over its parent's and BIOS's.
        for archive in archives:
            subprocess.run(
                [SEVENZIP, "x", "-y", f"-o{tmp}", str(archive)],
                check=True,
                stdout=subprocess.DEVNULL,
            )
        part = target.with_name(target.name + ".part")
        with zipfile.ZipFile(part, "w", zipfile.ZIP_DEFLATED) as zip_file:
            for path in sorted(Path(tmp).rglob("*")):
                if path.is_file():
                    zip_file.write(path, path.relative_to(tmp))
        os.replace(part, target)


def main():
    games = load_dat()
    TARGET.mkdir(parents=True, exist_ok=True)
    for part in TARGET.glob("*.part"):
        part.unlink()

    sets = {path.stem: path for path in SOURCE.glob("*.7z")}
    wanted = set()
    for name, source in sorted(sets.items()):
        game = games.get(name)
        if game and game["isbios"]:
            continue
        needed = needed_sets(name, games)
        dependencies = [sets[s] for s in needed if s in sets]
        target = TARGET / f"{name}.zip"
        wanted.add(target.name)

        newest = max(path.stat().st_mtime for path in [source, *dependencies])
        if target.exists() and target.stat().st_mtime >= newest:
            continue

        missing = [s for s in needed if s not in sets]
        if missing:
            log(f"{name}: {', '.join(missing)} isn't in the library; building without it")
        try:
            build([*reversed(dependencies), source], target)
        except subprocess.CalledProcessError:
            # An unfinished download, most likely; the next run tries again.
            log(f"{name}: couldn't unpack a set; skipped")
            continue
        with_sets = f" with {', '.join(d.stem for d in dependencies)}" if dependencies else ""
        log(f"built {target.name}{with_sets}")

    for stale in TARGET.glob("*.zip"):
        if stale.name not in wanted:
            stale.unlink()
            log(f"removed {stale.name}")


if __name__ == "__main__":
    main()
