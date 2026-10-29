"""Command-line entry point. Diagnostic mode does not require a graphical session."""

import argparse
import json
import logging
from pathlib import Path
import sys
import tempfile
import time

from . import __version__
from .core import pr_summary, run_summary
from .github import GitHub
from .monitor import Monitor
from .storage import Store


def print_menu(snapshot):
    now = time.time()
    print(f"Pipelight Linux · {snapshot['overall']} · fila: {snapshot['signal'] or 'sem sinal'}")
    for pr in snapshot["queue"]:
        print(f"  {pr.short_name}: {pr_summary(pr, now)}")
        if pr.key in snapshot["queue_errors"]:
            print("    ⚠ " + snapshot["queue_errors"][pr.key])
    for target in snapshot["targets"]:
        print(f"  {target.repo} · {target.branch}: {run_summary(snapshot['states'].get(target.key), now)}")
        if target.key in snapshot["errors"]:
            print("    ⚠ " + snapshot["errors"][target.key])
    if not snapshot["targets"]:
        print("  Adicione um repositório pelo menu da bandeja.")
    for key in ("config_error", "queue_error", "settings_error"):
        if snapshot[key]:
            print("  ⚠ " + snapshot[key])


def main(argv=None):
    parser = argparse.ArgumentParser(description="GitHub Actions e fila de PRs na bandeja do Linux.")
    parser.add_argument("--version", action="version", version="Pipelight " + __version__)
    parser.add_argument("--check", action="store_true", help="verifica dependências e o login do gh")
    parser.add_argument("--print-menu", action="store_true", help="consulta uma vez e imprime o estado, sem gravar arquivos")
    parser.add_argument("--data-dir", type=Path, help="pasta alternativa para config.json e queue.json")
    parser.add_argument("--demo", action="store_true", help="abre uma demonstração offline, com dados fictícios")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.WARNING,
                        format="%(asctime)s Pipelight %(levelname)s: %(message)s")
    if args.check:
        from .desktop import load_gtk
        load_gtk()
        print("✓ Python, GTK 3, AppIndicator e notificações disponíveis")
        GitHub().call("auth", "status", "--hostname", "github.com", json_output=False)
        print("✓ GitHub CLI autenticado")
        return 0
    temporary = tempfile.TemporaryDirectory(prefix="pipelight-demo-") if args.demo else None
    try:
        store = Store(temporary.name if temporary else args.data_dir, readonly=args.print_menu and not args.demo)
        github = GitHub()
        if args.demo:
            from .demo import DemoGitHub
            github = DemoGitHub()
            store.save_config({"repos": [{"repo": "acme/api", "branches": ["main", "homolog"], "workflow": "CI"}]})
        monitor = Monitor(store, github)
        if args.demo:
            monitor.add_pr("acme/api", 42)
        if args.print_menu:
            monitor.refresh()
            snapshot = monitor.snapshot()
            print_menu(snapshot)
            return int(bool(snapshot["errors"] or snapshot["queue_errors"] or snapshot["config_error"] or snapshot["queue_error"]))
        from .app import PipelightApp
        return PipelightApp(monitor, demo=args.demo).run(["pipelight"])
    finally:
        if temporary:
            temporary.cleanup()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError, ValueError) as exc:
        print(f"Pipelight: {exc}", file=sys.stderr)
        sys.exit(1)
