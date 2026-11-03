"""XDG paths, validated configuration, and atomic user-owned files."""

from dataclasses import asdict
import json
import os
from pathlib import Path
import tempfile

from .core import QueuedPR, Target, parse_repo


def xdg(variable, fallback):
    value = os.environ.get(variable)
    return Path(value) if value and Path(value).is_absolute() else Path.home() / fallback


def data_directory():
    return Path(os.environ["PIPELIGHT_DATA_DIR"]) if os.environ.get("PIPELIGHT_DATA_DIR") else xdg("XDG_CONFIG_HOME", ".config") / "pipelight"


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temp = tempfile.mkstemp(dir=path.parent, prefix="." + path.name)
    try:
        with os.fdopen(descriptor, "w") as output:
            json.dump(value, output, ensure_ascii=False, indent=2)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def validate_config(value):
    if not isinstance(value, dict) or not isinstance(value.get("repos", []), list):
        raise ValueError("config.json precisa ter uma lista 'repos'.")
    result = []
    seen = set()
    for item in value.get("repos", []):
        if not isinstance(item, dict) or not isinstance(item.get("repo"), str):
            raise ValueError("Cada repositório precisa de um campo 'repo'.")
        repo = parse_repo(item["repo"])
        branches = item.get("branches", ["main"])
        workflow = item.get("workflow")
        if not isinstance(branches, list) or not branches or not all(isinstance(b, str) and b.strip() for b in branches):
            raise ValueError("'branches' precisa ser uma lista de nomes de branches.")
        if workflow is not None and not isinstance(workflow, str):
            raise ValueError("'workflow' precisa ser um nome, arquivo ou ID em texto.")
        if repo.lower() in seen:
            raise ValueError("Repositório duplicado no config.json: " + repo)
        seen.add(repo.lower())
        result.append({"repo": repo, "branches": list(dict.fromkeys(b.strip() for b in branches)),
                       "workflow": (workflow or "").strip() or None})
    return {"repos": result}


def targets(config):
    return [Target(r["repo"], branch, r.get("workflow")) for r in config["repos"] for branch in r["branches"]]


class Store:
    def __init__(self, directory=None, readonly=False):
        self.directory = (Path(directory) if directory else data_directory()).resolve()
        self.readonly = readonly
        self.config = {"repos": []}
        self.config_error = None
        self.queue_error = None
        self.settings_error = None
        self.queue = []
        self.settings = {"notifyPassed": True}
        self.reload_config()
        path = self.directory / "queue.json"
        try:
            data = json.loads(path.read_text())
            if not isinstance(data, list):
                raise ValueError("expected a list")
            for item in data:
                if not isinstance(item, dict) or type(item.get("number")) is not int or item["number"] < 1:
                    raise ValueError("invalid queue entry")
                item["repo"] = parse_repo(item["repo"])
                self.queue.append(QueuedPR(**{k: v for k, v in item.items() if k in QueuedPR.__dataclass_fields__}))
        except FileNotFoundError:
            pass
        except (OSError, ValueError, TypeError, KeyError):
            self.queue = []
            self.queue_error = "queue.json inválido; corrija o arquivo antes de alterar a fila"
        try:
            settings = json.loads((self.directory / "settings.json").read_text())
            if not isinstance(settings, dict) or type(settings.get("notifyPassed", True)) is not bool:
                raise ValueError("invalid preferences")
            self.settings.update(settings)
        except FileNotFoundError:
            pass
        except (OSError, ValueError, TypeError):
            self.settings_error = "settings.json inválido; usando as preferências padrão"

    def reload_config(self):
        path = self.directory / "config.json"
        try:
            config = validate_config(json.loads(path.read_text()))
        except FileNotFoundError:
            config = {"repos": []}
            if not self.readonly:
                atomic_json(path, config)
        except (OSError, ValueError, TypeError) as exc:
            self.config_error = "config.json inválido; mantendo a última configuração válida: " + str(exc)[:140]
            return
        self.config, self.config_error = config, None

    def save_config(self, config):
        config = validate_config(config)
        if not self.readonly:
            atomic_json(self.directory / "config.json", config)
        self.config, self.config_error = config, None

    def save_queue(self):
        if self.queue_error:
            raise ValueError(self.queue_error)
        if not self.readonly:
            atomic_json(self.directory / "queue.json", [asdict(pr) for pr in self.queue])

    def save_settings(self, settings):
        if not self.readonly:
            atomic_json(self.directory / "settings.json", settings)
        self.settings, self.settings_error = settings, None
