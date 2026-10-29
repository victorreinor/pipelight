"""Small Linux desktop helpers shared by the application and installer."""

import os
import math
from pathlib import Path
import sys

from .storage import xdg

APP_ID = "dev.victorreinor.pipelight"
SPIN_FRAMES = 12
ICON_REVISION = "mac-v3-single"
COLORS = {"green": "#34C759", "red": "#FF3B30", "orange": "#FF9500",
          "blue": "#007AFF", "gray": "#8E8E93"}


def desktop_quote(value):
    # Desktop Entry Exec has its own escaping rules, not shell quoting.
    value = str(value).replace("%", "%%")
    for char in ("\\", '"', "`", "$"):
        value = value.replace(char, "\\" + char)
    return '"' + value + '"'


def desktop_entry(launcher, icon):
    return ("[Desktop Entry]\nType=Application\nVersion=1.0\nName=Pipelight\n"
            "Comment=Acompanhe o GitHub Actions e sua fila de PRs\n"
            f"Exec={desktop_quote(launcher)}\nIcon={icon}\nTerminal=false\n"
            "Categories=Development;\nStartupNotify=false\n"
            f"StartupWMClass={APP_ID}\nX-GNOME-Autostart-enabled=true\n")


def launcher_path():
    return Path(os.environ.get("PIPELIGHT_LAUNCHER", str(Path.home() / ".local/bin/pipelight")))


def autostart_path():
    return xdg("XDG_CONFIG_HOME", ".config") / "autostart" / f"{APP_ID}.desktop"


def set_autostart(enabled, icon):
    path = autostart_path()
    if enabled:
        launcher = launcher_path()
        if not launcher.is_file():
            raise ValueError("Instale o aplicativo com scripts/install-linux.sh para ativar o início automático.")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(desktop_entry(launcher, icon))
    else:
        path.unlink(missing_ok=True)


def load_gtk():
    try:
        import gi
        gi.require_version("Gtk", "3.0")
        gi.require_version("Notify", "0.7")
        try:
            gi.require_version("AyatanaAppIndicator3", "0.1")
            from gi.repository import AyatanaAppIndicator3 as Indicator
        except ValueError:
            gi.require_version("AppIndicator3", "0.1")
            from gi.repository import AppIndicator3 as Indicator
        from gi.repository import Gtk, GLib, Gio, Notify
        return Gtk, GLib, Gio, Notify, Indicator
    except (ImportError, ValueError) as exc:
        raise RuntimeError("Dependência gráfica ausente. No Ubuntu/Debian, instale:\n"
                           "sudo apt install python3-gi gir1.2-gtk-3.0 gir1.2-notify-0.7 "
                           "gir1.2-ayatanaappindicator3-0.1\n"
                           "Use /usr/bin/python3 (o Python do sistema).") from exc


def sync_arrows():
    """Two clockwise white arrows, matching scripts/make-icon.swift's geometry."""
    paths = []
    radius = 4.8
    for start in (165, -15):
        end = start - 120
        def point(degrees):
            angle = math.radians(degrees)
            return 12 + radius * math.cos(angle), 12 - radius * math.sin(angle)
        first, last, head = point(start), point(end + 14), point(end)
        angle = math.radians(end)
        tangent, normal = (math.sin(angle), math.cos(angle)), (math.cos(angle), -math.sin(angle))
        tip = (head[0] + tangent[0] * 3, head[1] + tangent[1] * 3)
        left = (head[0] + normal[0] * 2.4 - tangent[0] * .8,
                head[1] + normal[1] * 2.4 - tangent[1] * .8)
        right = (head[0] - normal[0] * 2.4 - tangent[0] * .8,
                 head[1] - normal[1] * 2.4 - tangent[1] * .8)
        paths.append(f'<path d="M{first[0]:.3f} {first[1]:.3f} A{radius} {radius} 0 0 1 {last[0]:.3f} {last[1]:.3f}" '
                     'fill="none" stroke="white" stroke-width="2" stroke-linecap="round"/>')
        paths.append(f'<path d="M{tip[0]:.3f} {tip[1]:.3f} L{left[0]:.3f} {left[1]:.3f} '
                     f'L{right[0]:.3f} {right[1]:.3f} Z" fill="white" stroke="white" '
                     'stroke-width=".4" stroke-linejoin="round"/>')
    return "".join(paths)


def icon_svg(state="passed", frame=0):
    """One full-sized colored status symbol, without a secondary badge."""
    color_name = {"passed": "green", "ready": "blue", "failed": "red", "running-failed": "red",
                  "running": "orange", "queued": "orange", "waiting": "orange", "error": "orange"}.get(state, "gray")
    color = COLORS[color_name]
    if state in {None, "empty", "unknown"}:
        shape = (f'<circle cx="12" cy="12" r="9" fill="none" stroke="{color}" '
                 'stroke-width="1.8" stroke-dasharray="2.12 2.59" stroke-linecap="round"/>')
    elif state == "error":
        shape = (f'<path d="M10.3 3.6 Q12 .8 13.7 3.6 L22 18.2 Q23.5 21 20.3 21 H3.7 '
                 f'Q.5 21 2 18.2 Z" fill="{color}"/>'
                 '<path d="M12 8 V13" stroke="white" stroke-width="2.2" stroke-linecap="round"/>'
                 '<circle cx="12" cy="17" r="1.2" fill="white"/>')
    else:
        shape = f'<circle cx="12" cy="12" r="10" fill="{color}"/>'
        if state.startswith("running"):
            shape += f'<g transform="rotate({frame * 360 / SPIN_FRAMES:g} 12 12)">{sync_arrows()}</g>'
        else:
            path = {"passed": "M7.5 12 L10.5 15.2 L16.7 8.4",
                    "ready": "M7.5 12 L10.5 15.2 L16.7 8.4",
                    "failed": "M8.3 8.3 L15.7 15.7 M15.7 8.3 L8.3 15.7",
                    "queued": "M12 6.7 V12 L15.8 14.1",
                    "waiting": "M9.3 8 V16 M14.7 8 V16"}.get(state, "M7.7 12 H16.3")
            shape += (f'<path d="{path}" fill="none" stroke="white" stroke-width="2" '
                      'stroke-linecap="round" stroke-linejoin="round"/>')
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24">{shape}</svg>'


class Icons:
    def __init__(self, directory=None):
        self.directory = Path(directory) if directory else xdg("XDG_CACHE_HOME", ".cache") / "pipelight/icons"
        self.directory.mkdir(parents=True, exist_ok=True)

    def get(self, state, frame=0):
        # Revisioned names also invalidate GNOME's icon cache after an application update.
        path = self.directory / f"pipelight-{ICON_REVISION}-{state or 'unknown'}-{frame}.svg"
        if not path.exists():
            path.write_text(icon_svg(state, frame))
        return str(path)
