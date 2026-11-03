"""Exercise actual GTK forms, tray export, and notification actions on an isolated desktop."""

import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time

from pipelight.app import PipelightApp, Gtk, GLib, Gio
from pipelight.core import Notice
from pipelight.demo import DemoGitHub
from pipelight.monitor import Monitor
from pipelight.storage import Store
from gi.repository import Gdk


def wait_until(condition, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        while GLib.MainContext.default().pending():
            GLib.MainContext.default().iteration(False)
        if condition():
            return
        time.sleep(0.01)
    raise AssertionError("GTK operation did not complete")


def labels(menu):
    result = []
    for child in menu.get_children():
        if isinstance(child, Gtk.MenuItem):
            result.append(child.get_label() or "")
            if child.get_submenu():
                result.extend(labels(child.get_submenu()))
    return result


def read_event(server, expected):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            event = json.loads(server.events.get(timeout=0.1))
            if expected in event:
                return event[expected]
        except queue.Empty:
            pass
        while GLib.MainContext.default().pending():
            GLib.MainContext.default().iteration(False)
    raise AssertionError("No D-Bus event: " + expected)


def exported_menu():
    """Read the actual tray menu protocol consumed by GNOME, not just GTK widgets."""
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    results = []
    def received(connection, result):
        results.append(connection.call_finish(result).unpack())
    bus.call(bus.get_unique_name(), "/org/ayatana/NotificationItem/dev_victorreinor_pipelight_demo/Menu",
             "com.canonical.dbusmenu", "GetLayout", GLib.Variant("(iias)", (0, -1, ["label", "icon-data"])),
             None, Gio.DBusCallFlags.NONE, 5000, None, received)
    wait_until(lambda: bool(results))
    return results[0][1][2]


def main():
    # Must be run with dbus-run-session, so this fake notification server cannot affect the desktop.
    assert os.environ.get("DBUS_SESSION_BUS_ADDRESS"), "Run inside dbus-run-session"
    server = subprocess.Popen([sys.executable, str(Path(__file__).with_name("fake_desktop.py"))],
                              stdout=subprocess.PIPE, text=True, bufsize=1)
    server.events = queue.Queue()
    def collect():
        for line in server.stdout:
            server.events.put(line)
    threading.Thread(target=collect, daemon=True).start()
    try:
        assert server.events.get(timeout=5).strip() == "ready"
        with tempfile.TemporaryDirectory(prefix="pipelight-gtk-test-") as temp:
            store = Store(temp)
            store.save_config({"repos": [{"repo": "acme/api", "branches": ["main", "homolog"], "workflow": "CI"}]})
            monitor = Monitor(store, DemoGitHub())
            monitor.add_pr("acme/api", 42)
            app = PipelightApp(monitor, demo=True)
            app.register(None)
            app.activate()
            wait_until(lambda: not app.refreshing and not app.loading_candidates)
            assert any("homolog — rodando" in s for s in labels(app.menu))
            assert any("pronto para mergear" in s for s in labels(app.menu))
            assert app.snapshot["overall"] == "running"
            assert app.snapshot["signal"] == "ready"
            assert app.snapshot["icon_state"] == "running"
            # Queue-only activity must animate even when no branch is configured.
            branch_overall = app.snapshot["overall"]
            app.snapshot["overall"] = "empty"
            app.frame = 0
            app.animate()
            assert app.frame == 1
            assert "single-running-1.svg" in app.indicator.get_icon()
            app.snapshot["overall"] = branch_overall
            assert read_event(server, "indicator")
            rows = [properties for _, properties, _ in exported_menu() if "—" in properties.get("label", "")]
            assert len(rows) == 3
            assert all(bytes(row["icon-data"]).startswith(b"\x89PNG") for row in rows)
            assert all(not any(emoji in row["label"] for emoji in ("🔵", "🟠", "🔴", "✓", "◌")) for row in rows)

            # Empty-state rows that looked like disabled headings must open setup.
            store.save_config({"repos": []})
            monitor.store.reload_config()
            app.snapshot = monitor.snapshot()
            app.rebuild()
            empty_actions = [row for row in app.menu.get_children()
                             if row.get_label() in {"Adicionar um repositório para começar", "Adicionar repositório…"}]
            assert [item.get_label() for item in empty_actions] == ["Adicionar um repositório para começar"]
            item = empty_actions[0]
            assert item.get_sensitive()
            assert item.get_tooltip_text()
            item.activate()
            dialog = next(d for d in app.dialogs if d.get_title() == "Adicionar repositório")
            dialog.destroy()

            repo = app.add_repo_dialog()
            repo.pipelight_entries[0].set_text("not a repository")
            repo.response(Gtk.ResponseType.OK)
            assert repo in app.dialogs  # Invalid input stays editable.
            for entry, value in zip(repo.pipelight_entries, ["acme/web", "main, homolog", "CI"]):
                entry.set_text(value)
            repo.response(Gtk.ResponseType.OK)
            wait_until(lambda: repo not in app.dialogs and not app.refreshing)
            assert len(store.config["repos"]) == 2

            dialog = app.add_pr_dialog()
            dialog.pipelight_entries[0].set_text("https://github.com/acme/web/pull/43/files")
            dialog.response(Gtk.ResponseType.OK)
            wait_until(lambda: dialog not in app.dialogs and not app.refreshing)
            assert len(store.queue) == 2

            # Toggle the real settings control and confirm persistence through the worker.
            toggle = next(c for c in app.menu.get_children() if isinstance(c, Gtk.CheckMenuItem) and c.get_label().startswith("Avisar"))
            toggle.set_active(False)
            wait_until(lambda: not store.settings["notifyPassed"])
            assert json.loads((Path(temp) / "settings.json").read_text())["notifyPassed"] is False

            opened = []
            app.open_url = opened.append
            app.demo = False  # Only for the isolated fake notification service.
            app.notify(Notice("CI quebrou", "Commit <test> & detalhe", "https://github.com/acme/api/actions/runs/1", "failed"))
            notification = read_event(server, "notification")
            assert notification[3] == "CI quebrou"
            assert "&lt;test&gt;" in notification[4]
            assert notification[6]["suppress-sound"] is False
            wait_until(lambda: len(opened) == 1)
            app.demo = True

            # Render the real dialog, rather than an independently drawn mockup.
            dialog = app.add_repo_dialog()
            for entry, value in zip(dialog.pipelight_entries, ["acme/api", "main, homolog", "Continuous integration"]):
                entry.set_text(value)
            wait_until(lambda: dialog.get_window() is not None)
            for _ in range(10):
                GLib.MainContext.default().iteration(False)
                time.sleep(0.02)
            output = Path("build.noindex/linux-smoke.png")
            output.parent.mkdir(parents=True, exist_ok=True)
            pixbuf = Gdk.pixbuf_get_from_window(dialog.get_window(), 0, 0, dialog.get_allocated_width(), dialog.get_allocated_height())
            pixbuf.savev(str(output), "png", [], [])
            dialog.destroy()

            anchor = Gtk.Window()
            anchor.set_default_size(100, 40)
            anchor.move(20, 20)
            button = Gtk.Button(label="Pipelight")
            anchor.add(button)
            anchor.show_all()
            app.menu.popup_at_widget(button, Gdk.Gravity.SOUTH_WEST, Gdk.Gravity.NORTH_WEST, None)
            wait_until(lambda: app.menu.get_mapped())
            for _ in range(10):
                GLib.MainContext.default().iteration(False)
                time.sleep(0.02)
            menu_image = Gdk.pixbuf_get_from_window(app.menu.get_window(), 0, 0,
                                                  app.menu.get_allocated_width(), app.menu.get_allocated_height())
            menu_image.savev(str(output.with_name("linux-menu-smoke.png")), "png", [], [])
            app.menu.popdown()
            anchor.destroy()

            app.remove_prs({("acme/web", 43)})
            wait_until(lambda: len(store.queue) == 1 and not app.refreshing)
            app.shutdown_app()
            app.executor.shutdown(wait=True)
            print("OK: GTK menu, tray registration, forms, validation, settings, notification and click, queue removal")
            print("Screenshot:", output.resolve())
    finally:
        server.terminate()
        server.wait(timeout=5)


if __name__ == "__main__":
    main()
