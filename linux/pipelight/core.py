"""Platform-independent status and notification rules, ported from PipelightCore."""

from dataclasses import dataclass, field
from datetime import datetime, timezone
import re
from urllib.parse import quote, urlparse

ACTIVE = {"queued", "running", "waiting"}
LABELS = {"queued": "na fila", "running": "rodando", "waiting": "aguardando aprovação",
          "passed": "passou", "failed": "quebrou", "cancelled": "cancelado", "neutral": "sem resultado"}
SYMBOLS = {"passed": "✓", "failed": "✕", "running": "◌", "queued": "◷",
           "waiting": "◷", "cancelled": "−", "neutral": "−", None: "·"}


def timestamp(value):
    if not value or str(value).startswith("0001-"):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (ValueError, TypeError, AttributeError):
        return None


def run_state(status, conclusion):
    status, conclusion = (status or "").lower(), (conclusion or "").lower()
    if status == "completed":
        if conclusion == "success":
            return "passed"
        if conclusion in {"failure", "timed_out", "startup_failure", "error"}:
            return "failed"
        return {"cancelled": "cancelled", "action_required": "waiting"}.get(conclusion, "neutral")
    if status in {"queued", "requested", "pending"}:
        return "queued"
    if status in {"waiting", "action_required"}:
        return "waiting"
    return "running"


def parse_repo(text):
    text = text.strip()
    for prefix in ("git@github.com:", "ssh://git@github.com/"):
        if text.lower().startswith(prefix):
            text = text[len(prefix):]
            break
    if text.startswith(("https://", "http://")):
        url = urlparse(text)
        if url.hostname not in {"github.com", "www.github.com"}:
            raise ValueError("Use um repositório do github.com: dono/nome.")
        text = url.path.lstrip("/")
    else:
        text = re.sub(r"^(?:www\.)?github\.com/", "", text, flags=re.I)
    parts = text.strip("/").split("/")
    if len(parts) < 2:
        raise ValueError("Informe o repositório como dono/nome ou cole o link do GitHub.")
    owner, name = parts[0], parts[1].removesuffix(".git")
    if not all(re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]*", p) and p not in {".", ".."}
               for p in (owner, name)):
        raise ValueError("Nome de repositório inválido. Use dono/nome.")
    return f"{owner}/{name}"


def parse_pr(text):
    for pattern in (r"(?<![\w.-])(?:https?://)?github\.com/([\w.-]+/[\w.-]+)/pull/(\d+)\b",
                    r"(?<![\w./-])([\w.-]+/[\w.-]+)#(\d+)\b"):
        match = re.search(pattern, text)
        if match and int(match[2]) > 0:
            return parse_repo(match[1]), int(match[2])
    raise ValueError("Cole um link de PR do GitHub ou use dono/nome#123.")


def parse_branches(text):
    return list(dict.fromkeys(re.split(r"[,\s]+", text.strip()))) if text.strip() else []


@dataclass(frozen=True)
class Target:
    repo: str
    branch: str
    workflow: str | None = None

    @property
    def key(self):
        return self.repo.lower(), self.branch, self.workflow or ""

    @property
    def url(self):
        return f"https://github.com/{self.repo}/actions?query={quote('branch:' + self.branch, safe='')}"


@dataclass
class Run:
    id: int
    attempt: int = 1
    workflow: str = ""
    title: str = ""
    status: str = "completed"
    conclusion: str = ""
    created: float = 0
    started: float = 0
    updated: float = 0
    url: str = ""

    @classmethod
    def from_api(cls, data):
        created = timestamp(data.get("created_at")) or 0
        return cls(id=data["id"], attempt=data.get("run_attempt", 1),
                   workflow=data.get("name") or str(data.get("workflow_id", "")),
                   title=data.get("display_title") or "", status=data["status"],
                   conclusion=data.get("conclusion") or "", created=created,
                   started=timestamp(data.get("run_started_at")) or created,
                   updated=timestamp(data.get("updated_at")) or created,
                   url=data.get("html_url", ""))

    @property
    def state(self):
        return run_state(self.status, self.conclusion)

    @property
    def active(self):
        return self.state in ACTIVE

    @property
    def key(self):
        return self.id, self.attempt


@dataclass
class BranchStatus:
    headline: Run | None = None
    previous: Run | None = None

    @classmethod
    def from_runs(cls, runs):
        relevant = [r for r in runs if r.conclusion != "skipped"]
        latest = {}
        for run in relevant:
            latest.setdefault(run.workflow, run)
        values = list(latest.values())
        headline = (next((r for r in values if r.active), None)
                    or next((r for r in values if r.state == "failed"), None)
                    or next(iter(values), None))
        previous = next((r for r in relevant if headline and headline.active and
                         r.workflow == headline.workflow and r.id != headline.id and not r.active), None)
        return cls(headline, previous)

    @property
    def active(self):
        return bool(self.headline and self.headline.active)

    @property
    def state(self):
        return self.headline.state if self.headline else None


def overall(statuses):
    if not statuses:
        return "empty"
    states = [s.state for s in statuses if s]
    if any(s in ACTIVE for s in states):
        return "running-failed" if "failed" in states else "running"
    if "failed" in states:
        return "failed"
    return "passed" if any(states) else "unknown"


def tray_state(branch_state, queue):
    """One prominent status for everything watched, including PR-only setups."""
    failing = branch_state in {"failed", "running-failed"} or any(
        pr.checks in {"failed", "cancelled"} for pr in queue)
    running = branch_state.startswith("running") or any(
        pr.base_busy or pr.checks in ACTIVE for pr in queue)
    if running:
        return "running-failed" if failing else "running"
    if failing:
        return "failed"
    if any(pr.signal == "ready" for pr in queue):
        return "ready"
    if queue and branch_state in {"empty", "unknown"}:
        return "queued" if any(pr.signal == "running" for pr in queue) else "unknown"
    return branch_state


@dataclass
class Notice:
    title: str
    body: str
    url: str
    kind: str = "passed"
    queue: bool = False
    place: tuple | None = None

    @property
    def sound(self):
        return self.queue or self.kind == "failed"


class CompletionTracker:
    def __init__(self):
        self.seen = {}

    def forget(self, target):
        self.seen.pop(target, None)

    def completions(self, target, runs):
        primed = target in self.seen
        seen = self.seen.setdefault(target, set())
        found = []
        for index, run in enumerate(runs):
            if run.active or run.key in seen:
                continue
            seen.add(run.key)
            if primed:
                previous = next((r for r in runs[index + 1:] if r.workflow == run.workflow
                                 and r.state in {"passed", "failed"}), None)
                found.append((run, previous))
        # Only the recent query window can appear in the next comparison.
        self.seen[target] = {r.key for r in runs if not r.active}
        return found


def branch_notice(target, run, previous):
    if run.state not in {"passed", "failed"}:
        return None
    fixed = run.state == "passed" and previous and previous.state == "failed"
    label = "voltou a passar" if fixed else LABELS[run.state]
    symbol = "❌" if run.state == "failed" else "✅"
    return Notice(f"{symbol} {target.repo.split('/')[-1]} · {target.branch} {label}",
                  f"{run.workflow} · {duration(run.updated - run.started)}\n{run.title}", run.url,
                  "fixed" if fixed else run.state, place=(target.repo.lower(), target.branch))


def summarize_checks(checks, workflow=None):
    by_name = workflow and not (workflow.lower().endswith((".yml", ".yaml")) or workflow.isdigit())
    latest = {}
    for raw in checks or []:
        check = dict(raw)
        if by_name and (check.get("workflowName") or "").lower() != workflow.lower():
            continue
        if check.get("__typename") == "StatusContext":
            value = check.get("state", "")
            check["status"] = "IN_PROGRESS" if value in {"PENDING", "EXPECTED"} else "COMPLETED"
            check["conclusion"] = "SUCCESS" if value == "SUCCESS" else "FAILURE"
        key = (check.get("workflowName", ""), check.get("name") or check.get("context", ""))
        started = timestamp(check.get("startedAt")) or timestamp(check.get("createdAt")) or 0
        if key not in latest or started >= latest[key][0]:
            latest[key] = (started, check)
    states = [run_state(c.get("status", "COMPLETED"), c.get("conclusion")) for _, c in latest.values()]
    if not states:
        state = None
    else:
        state = next((s for s in ("running", "waiting", "queued", "failed") if s in states), None)
        state = state or ("cancelled" if all(s == "cancelled" for s in states) else "passed")
    starts = [s for s, _ in latest.values() if s]
    ends = [timestamp(c.get("completedAt")) for _, c in latest.values()]
    ends = [s for s in ends if s]
    return state, min(starts, default=None), max(ends, default=None) if state not in ACTIVE else None


@dataclass
class QueuedPR:
    repo: str
    number: int
    title: str = ""
    author: str = ""
    url: str = ""
    base: str | None = None
    base_busy: bool | None = None
    sha: str = ""
    checks: str | None = None
    started: float | None = None
    finished: float | None = None
    announced: str | None = None
    draft: bool = False

    @property
    def key(self):
        return self.repo.lower(), self.number

    @property
    def short_name(self):
        return f"{self.repo.split('/')[-1]} #{self.number}"

    @property
    def signal(self):
        if self.base_busy is not False:
            return None
        return {"passed": "ready", "failed": "failed", "cancelled": "failed"}.get(self.checks, "running")

    @property
    def result_key(self):
        return f"{self.sha}:{self.checks}" if self.checks in {"passed", "failed"} else None

    def update(self, pr, base_status, workflow=None, initial=False):
        retargeted = self.base != pr.get("baseRefName")
        was_busy = None if retargeted else self.base_busy
        self.title, self.author = pr.get("title", ""), (pr.get("author") or {}).get("login", "")
        self.url = pr.get("url") or f"https://github.com/{self.repo}/pull/{self.number}"
        self.base, self.sha = pr.get("baseRefName"), pr.get("headRefOid", "")
        self.draft = bool(pr.get("isDraft"))
        self.base_busy = base_status.active if base_status is not None else was_busy
        self.checks, self.started, self.finished = summarize_checks(pr.get("statusCheckRollup"), workflow)
        result = self.result_key
        if initial or retargeted or was_busy is None:
            self.announced = result
            return None
        # A failed base query must not turn a stale free state into a new notification.
        if self.base_busy is not False or base_status is None:
            return None
        if was_busy:
            self.announced = result or self.announced
            state = base_status.state
            prefix = "❌" if state == "failed" else "✅"
            label = LABELS.get(state, "liberou") if state in {"passed", "failed"} else "liberou"
            ci = {"passed": "pronto para mergear", "failed": "CI do PR quebrou",
                  "cancelled": "CI do PR cancelado"}.get(self.checks, "CI do PR ainda rodando")
            return Notice(f"{prefix} {self.repo.split('/')[-1]} · {self.base} {label}",
                          f"#{self.number}: {ci}\n{self.title}", self.url,
                          "failed" if state == "failed" else "passed", True,
                          (self.repo.lower(), self.base))
        if result and result != self.announced:
            fixed = self.checks == "passed" and (self.announced or "").endswith(":failed")
            self.announced = result
            title = (f"✅ {self.short_name} pronto para mergear" if self.checks == "passed"
                     else f"❌ {self.short_name}: CI do PR quebrou")
            return Notice(title, f"{self.base} livre · CI {'voltou a passar' if fixed else LABELS[self.checks]}\n{self.title}",
                          self.url, "fixed" if fixed else self.checks, True)
        return None


def duration(seconds):
    total = max(0, int(seconds))
    if total < 60:
        return f"{total} s"
    if total < 3600:
        return f"{total // 60} min"
    minutes = total % 3600 // 60
    return f"{total // 3600} h" + (f" {minutes:02} min" if minutes else "")


def ago(date, now):
    seconds = max(0, now - date)
    if seconds < 60:
        return "agora"
    if seconds < 3600:
        return f"há {int(seconds // 60)} min"
    if seconds < 86400:
        return f"há {int(seconds // 3600)} h"
    days = int(seconds // 86400)
    return f"há {days} {'dia' if days == 1 else 'dias'}"


def run_summary(status, now):
    if not status or not status.headline:
        return "sem execuções"
    run = status.headline
    if run.state == "queued":
        text = f"na fila há {duration(now - run.created)}"
    elif run.state == "running":
        text = f"rodando há {duration(now - run.started)}"
    elif run.state == "waiting":
        text = "aguardando aprovação"
    else:
        text = f"{LABELS[run.state]} em {duration(run.updated - run.started)} · {ago(run.updated, now)}"
    if run.active and status.previous:
        text += f" · antes {LABELS[status.previous.state]}"
    return text


def pr_summary(pr, now):
    ci = "esperando os checks" if pr.checks is None else "CI " + LABELS[pr.checks]
    if pr.checks == "running" and pr.started:
        ci += " há " + duration(now - pr.started)
    elif pr.checks in {"passed", "failed"} and pr.finished:
        ci += " " + ago(pr.finished, now)
    if pr.base_busy:
        return f"esperando o {pr.base} · {ci}"
    if pr.base_busy is False:
        return f"pronto para mergear · {pr.base} livre" if pr.signal == "ready" else f"{pr.base} livre · {ci}"
    return ci


def polling_interval(requests, running):
    return max(15 if running else 30, requests * 3600 / 2000)
