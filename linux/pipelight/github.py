"""GitHub access through the user's gh login; no credentials are stored here."""

import json
import os
import shutil
import subprocess
import threading
import time
from urllib.parse import quote, urlencode

from .core import Run, parse_repo

PR_FIELDS = "number,title,url,author,state,isDraft,baseRefName,headRefOid,statusCheckRollup"
SEARCH_FIELDS = "number,title,repository,author,isDraft,updatedAt,url"


class GitHubError(RuntimeError):
    pass


def explain(stderr):
    text = stderr.lower()
    messages = [
        (("gh auth login", "authentication", "http 401"), "gh sem login: rode gh auth login no Terminal"),
        (("rate limit",), "limite de requisições do GitHub atingido; tente mais tarde"),
        (("could not resolve to a pullrequest",), "PR não encontrado nesse repositório"),
        (("http 404", "could not resolve to a repository"), "repositório não encontrado (ou sem acesso)"),
        (("could not find any workflows",), "workflow não encontrado nesse repositório"),
        (("error connecting", "dial tcp", "no such host", "timeout", "network is unreachable", "tls handshake"),
         "sem conexão com o GitHub"),
    ]
    for patterns, message in messages:
        if any(p in text for p in patterns):
            return message
    return (stderr.strip().splitlines() or ["erro desconhecido do gh"])[0][:240]


class GitHub:
    def __init__(self, executable=None):
        self.executable = executable or shutil.which("gh")
        if not self.executable:
            for path in ("/usr/bin/gh", "/usr/local/bin/gh", os.path.expanduser("~/.local/bin/gh"), "/snap/bin/gh"):
                if os.access(path, os.X_OK):
                    self.executable = path
                    break
        self._workflow_cache = {}
        self._workflow_lock = threading.Lock()

    def call(self, *args, json_output=True):
        if not self.executable:
            raise GitHubError("gh não encontrado: instale o GitHub CLI e rode gh auth login")
        env = {**os.environ, "GH_PROMPT_DISABLED": "1", "GH_PAGER": "cat", "NO_COLOR": "1"}
        try:
            result = subprocess.run([self.executable, *args], capture_output=True, text=True,
                                    timeout=30, env=env, stdin=subprocess.DEVNULL)
        except subprocess.TimeoutExpired as exc:
            raise GitHubError("o GitHub não respondeu em 30 segundos") from exc
        except OSError as exc:
            raise GitHubError("não foi possível executar o GitHub CLI") from exc
        if result.returncode:
            raise GitHubError(explain(result.stderr or result.stdout))
        if not json_output:
            return result.stdout.strip()
        try:
            return json.loads(result.stdout)
        except ValueError as exc:
            raise GitHubError("o gh devolveu uma resposta inválida") from exc

    def workflow_id(self, repo, workflow):
        if workflow.isdigit() or workflow.lower().endswith((".yml", ".yaml")):
            return workflow.rsplit("/", 1)[-1]
        key = repo.lower(), workflow.lower()
        with self._workflow_lock:
            cached = self._workflow_cache.get(key)
            if cached and time.monotonic() - cached[0] < 300:
                return cached[1]
            pages = self.call("api", "--hostname", "github.com", "--paginate",
                              f"repos/{repo}/actions/workflows?per_page=100", json_output=False)
            # gh 2.45 emits separate JSON documents for --paginate.
            decoder, text = json.JSONDecoder(), pages.strip()
            while text:
                page, end = decoder.raw_decode(text)
                for item in page.get("workflows", []):
                    if item["name"].lower() == workflow.lower():
                        result = str(item["id"])
                        self._workflow_cache[key] = time.monotonic(), result
                        return result
                text = text[end:].lstrip()
        raise GitHubError("workflow não encontrado nesse repositório")

    def runs(self, target):
        repo = parse_repo(target.repo)
        path = f"repos/{repo}/actions"
        if target.workflow:
            path += "/workflows/" + quote(self.workflow_id(repo, target.workflow), safe="")
        path += "/runs?" + urlencode({"branch": target.branch, "per_page": 5 if target.workflow else 20})
        response = self.call("api", "--hostname", "github.com", path)
        return [Run.from_api(r) for r in response["workflow_runs"]]

    def pull_request(self, repo, number):
        return self.call("pr", "view", str(number), "--repo", "https://github.com/" + parse_repo(repo),
                         "--json", PR_FIELDS)

    def validate_repo(self, repo, branches, workflow):
        result = self.call("repo", "view", "https://github.com/" + parse_repo(repo),
                           "--json", "nameWithOwner,defaultBranchRef")
        repo = result["nameWithOwner"]
        branches = branches or [(result.get("defaultBranchRef") or {}).get("name") or "main"]
        for branch in branches:
            self.call("api", "--hostname", "github.com", f"repos/{repo}/branches/{quote(branch, safe='')}")
        if workflow:
            ident = self.workflow_id(repo, workflow)
            self.call("api", "--hostname", "github.com", f"repos/{repo}/actions/workflows/{quote(ident, safe='')}")
        return {"repo": repo, "branches": branches, "workflow": workflow or None}

    def candidates(self, review=False):
        return self.call("search", "prs", "--review-requested=@me" if review else "--author=@me",
                         "--state", "open", "--limit", "12" if review else "8", "--sort", "updated",
                         "--order", "desc", "--json", SEARCH_FIELDS)
