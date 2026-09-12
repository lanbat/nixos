"""Write ES-DE's custom_systems/es_systems.xml for the Pi's TV games session.

Usage: es-de-systems.py BUNDLED_ES_SYSTEMS PREFERENCES_JSON SWITCH_DIR OUTPUT

ES-DE launches a game with the first emulator listed for its system. For each
system in PREFERENCES_JSON ({"psx": "PCSX ReARMed", ...}) this copies the
entry from ES-DE's bundled es_systems.xml with the emulator of that label
moved first. A "Kodi" system lists the scripts in SWITCH_DIR, which switch the
TV back to the Kodi session. An unknown system or label fails the build.
"""

import json
import sys
import xml.etree.ElementTree as ET

bundled, preferences, switch_dir, output = sys.argv[1:5]

with open(preferences) as f:
    wanted = json.load(f)

systems = {s.findtext("name"): s for s in ET.parse(bundled).getroot().findall("system")}
result = ET.Element("systemList")

for name, label in sorted(wanted.items()):
    system = systems.get(name)
    if system is None:
        sys.exit(f"ES-DE has no system named {name!r}")
    commands = system.findall("command")
    chosen = next((c for c in commands if c.get("label") == label), None)
    if chosen is None:
        labels = ", ".join(c.get("label") for c in commands)
        sys.exit(f"ES-DE system {name!r} has no emulator labelled {label!r} (it has: {labels})")
    position = list(system).index(commands[0])
    for command in commands:
        system.remove(command)
    for offset, command in enumerate([chosen] + [c for c in commands if c is not chosen]):
        system.insert(position + offset, command)
    result.append(system)

kodi = ET.SubElement(result, "system")
for tag, text, attributes in [
    ("name", "kodi", {}),
    ("fullname", "Kodi", {}),
    ("path", switch_dir, {}),
    ("extension", ".sh", {}),
    ("command", "%EMULATOR_OS-SHELL% %ROM%", {"label": "Switch to Kodi"}),
    ("platform", "kodi", {}),
    ("theme", "kodi", {}),
]:
    ET.SubElement(kodi, tag, attributes).text = text

ET.indent(result)
ET.ElementTree(result).write(output, encoding="unicode", xml_declaration=True)
