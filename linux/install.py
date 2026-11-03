#!/usr/bin/python3
"""Install into the user's account. No global Python packages or root writes."""

import argparse
import ctypes.util
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

from pipelight.desktop import APP_ID, desktop_entry
from pipelight.storage import xdg

SOURCE = Path(__file__).resolve().parent


def dependencies(vendor):
    if not shutil.which("gh"):
        raise RuntimeError("Instale o GitHub CLI (sudo apt install gh), rode gh auth login e tente novamente.")
    env = dict(os.environ)
    env["GI_TYPELIB_PATH"] = str(vendor) + (":" + env["GI_TYPELIB_PATH"] if env.get("GI_TYPELIB_PATH") else "")
    probe = "from pipelight.desktop import load_gtk; load_gtk()"
    result = subprocess.run([sys.executable, "-c", probe], env=env, cwd=SOURCE, capture_output=True, text=True)
    if result.returncode == 0:
        return
    # Ubuntu already ships the runtime for its system tray, but may omit its Python metadata.
    # apt-get download verifies the archive using APT's trusted package indexes.
    if ctypes.util.find_library("ayatana-appindicator3") and shutil.which("apt-get") and shutil.which("dpkg-deb"):
        print("→ Instalando os metadados do AppIndicator na sua conta…", flush=True)
        with tempfile.TemporaryDirectory(prefix="pipelight-deps-") as temp:
            subprocess.run(["apt-get", "download", "gir1.2-ayatanaappindicator3-0.1"], cwd=temp, check=True, timeout=120)
            package = next(Path(temp).glob("*.deb"))
            unpacked = Path(temp) / "unpacked"
            subprocess.run(["dpkg-deb", "-x", str(package), str(unpacked)], check=True)
            vendor.mkdir(parents=True, exist_ok=True)
            for typelib in unpacked.rglob("*.typelib"):
                shutil.copy2(typelib, vendor / typelib.name)
        result = subprocess.run([sys.executable, "-c", probe], env=env, cwd=SOURCE, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError("Instale as dependências do sistema e execute novamente:\n"
                           "sudo apt install python3-gi gir1.2-gtk-3.0 gir1.2-notify-0.7 "
                           "gir1.2-ayatanaappindicator3-0.1 gh")


def install(start=False):
    destination = xdg("XDG_DATA_HOME", ".local/share") / "pipelight"
    vendor = destination / "vendor"
    dependencies(vendor)
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copytree(SOURCE / "pipelight", destination / "pipelight", dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    shutil.copytree(SOURCE / "assets", destination / "assets", dirs_exist_ok=True)
    shutil.copy2(SOURCE / "README.md", destination / "README.md")
    license_file = SOURCE.parent / "LICENSE"
    if license_file.exists():
        shutil.copy2(license_file, destination / "LICENSE")
    binary_dir = Path.home() / ".local/bin"
    binary_dir.mkdir(parents=True, exist_ok=True)
    launcher = binary_dir / "pipelight"
    launcher.write_text("#!/bin/sh\n"
                        + "export PYTHONPATH=" + shlex.quote(str(destination)) + "\n"
                        + "export GI_TYPELIB_PATH=" + shlex.quote(str(vendor)) + '${GI_TYPELIB_PATH:+:$GI_TYPELIB_PATH}\n'
                        + "export PIPELIGHT_LAUNCHER=" + shlex.quote(str(launcher)) + "\n"
                        + "exec /usr/bin/python3 -m pipelight \"$@\"\n")
    launcher.chmod(0o755)
    applications = xdg("XDG_DATA_HOME", ".local/share") / "applications"
    applications.mkdir(parents=True, exist_ok=True)
    icon = destination / "assets/pipelight.svg"
    (applications / f"{APP_ID}.desktop").write_text(desktop_entry(launcher, icon))
    if shutil.which("update-desktop-database"):
        subprocess.run(["update-desktop-database", str(applications)], check=False, capture_output=True)
    print(f"✓ Instalado: {launcher}")
    print("Abra Pipelight no menu de aplicativos ou execute ~/.local/bin/pipelight.")
    print("No ícone da bandeja, escolha Adicionar repositório…")
    print("Para abrir junto com o Linux, marque essa opção no menu do Pipelight.")
    if start:
        log_dir = xdg("XDG_STATE_HOME", ".local/state") / "pipelight"
        log_dir.mkdir(parents=True, exist_ok=True)
        with (log_dir / "app.log").open("a") as log:
            subprocess.Popen([str(launcher)], stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Instala o Pipelight Linux na sua conta.")
    parser.add_argument("--start", action="store_true", help="abre o aplicativo após instalar")
    args = parser.parse_args()
    try:
        install(args.start)
    except (OSError, RuntimeError, subprocess.SubprocessError) as exc:
        sys.exit(str(exc))
