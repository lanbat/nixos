#!/usr/bin/env python3
"""
TV/sofa launcher for the Raspberry Pi 5 frontend.

A full-screen GTK3 menu with two large buttons: Kodi and RetroArch.
Runs as part of the openbox session (started from ~/.config/openbox/autostart).

When a button is pressed:
  1. The launcher window hides.
  2. The chosen application runs in a subprocess.
  3. When the application exits, the launcher reappears.

Controller navigation is supported via keyboard arrow keys + Enter.
"""

import subprocess
import sys
import os

try:
    import gi
    gi.require_version("Gtk", "3.0")
    gi.require_version("Gdk", "3.0")
    from gi.repository import Gtk, Gdk, GLib
except ImportError:
    sys.exit("GTK3 Python bindings not available. Install python3-gi.")

# ---------------------------------------------------------------------------
# Application definitions
# ---------------------------------------------------------------------------
APPS = [
    {
        "label": "Kodi",
        "icon":  "📺",
        "cmd":   ["kodi", "--standalone"],
        "color": "#1a73e8",
    },
    {
        "label": "RetroArch",
        "icon":  "🎮",
        "cmd":   ["retroarch"],
        "color": "#1e293b",
    },
    {
        "label": "Reboot",
        "icon":  "🔄",
        "cmd":   ["systemctl", "reboot"],
        "color": "#7c3aed",
    },
    {
        "label": "Shutdown",
        "icon":  "⏻",
        "cmd":   ["systemctl", "poweroff"],
        "color": "#dc2626",
    },
]

CSS = b"""
window {
    background-color: #0f172a;
}
.launcher-title {
    font-size: 2.5rem;
    font-weight: 700;
    color: #f1f5f9;
    padding: 40px 0 20px;
}
.launcher-btn {
    font-size: 1.6rem;
    font-weight: 600;
    color: #f1f5f9;
    border-radius: 16px;
    padding: 30px 60px;
    min-width: 260px;
    min-height: 120px;
    border: 3px solid transparent;
    transition: all 0.15s ease;
}
.launcher-btn:hover,
.launcher-btn:focus {
    border-color: #6366f1;
    box-shadow: 0 0 0 4px rgba(99,102,241,0.3);
}
.btn-kodi       { background-color: #1a73e8; }
.btn-kodi:hover { background-color: #1557b0; }
.btn-retroarch       { background-color: #1e293b; }
.btn-retroarch:hover { background-color: #0f172a; border-color: #6366f1; }
.btn-reboot       { background-color: #7c3aed; }
.btn-reboot:hover { background-color: #5b21b6; }
.btn-shutdown       { background-color: #dc2626; }
.btn-shutdown:hover { background-color: #991b1b; }
"""


class Launcher(Gtk.Window):
    def __init__(self):
        super().__init__()

        # Apply CSS.
        provider = Gtk.CssProvider()
        provider.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

        # Full-screen, no decorations.
        self.set_decorated(False)
        self.fullscreen()
        self.set_keep_above(True)

        # Close on Escape (safety valve).
        self.connect("key-press-event", self._on_key)
        self.connect("delete-event", Gtk.main_quit)

        # Main layout.
        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=20)
        vbox.set_halign(Gtk.Align.CENTER)
        vbox.set_valign(Gtk.Align.CENTER)
        self.add(vbox)

        title = Gtk.Label(label="Homelab TV")
        title.get_style_context().add_class("launcher-title")
        vbox.pack_start(title, False, False, 0)

        grid = Gtk.Grid()
        grid.set_column_spacing(20)
        grid.set_row_spacing(20)
        grid.set_halign(Gtk.Align.CENTER)
        vbox.pack_start(grid, False, False, 20)

        self.buttons = []
        for i, app in enumerate(APPS):
            btn = Gtk.Button(label=f"{app['icon']}  {app['label']}")
            btn.get_style_context().add_class("launcher-btn")
            btn.get_style_context().add_class(f"btn-{app['label'].lower()}")
            btn.connect("clicked", self._launch, app)
            col, row = i % 2, i // 2
            grid.attach(btn, col, row, 1, 1)
            self.buttons.append(btn)

        if self.buttons:
            GLib.idle_add(self.buttons[0].grab_focus)

        self.show_all()

    def _on_key(self, widget, event):
        if event.keyval == Gdk.KEY_Escape:
            pass  # Do nothing — no desktop to go back to.
        return False

    def _launch(self, _btn, app):
        self.hide()
        # Flush GTK events so the window actually hides.
        while Gtk.events_pending():
            Gtk.main_iteration()

        try:
            result = subprocess.run(app["cmd"])
        except FileNotFoundError:
            pass

        # Reshow launcher when app exits.
        self.show()
        if self.buttons:
            GLib.idle_add(self.buttons[0].grab_focus)


def main():
    # Wait a moment for X11 to settle on boot.
    import time
    time.sleep(1)

    app = Launcher()
    Gtk.main()


if __name__ == "__main__":
    main()
