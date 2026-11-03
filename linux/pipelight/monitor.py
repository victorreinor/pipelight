"""Serialized monitor operations; each poll fetches independent targets concurrently."""

from concurrent.futures import ThreadPoolExecutor, as_completed
import copy
import time

from .core import (ACTIVE, BranchStatus, CompletionTracker, QueuedPR, Target, branch_notice,
                   overall, polling_interval, tray_state)
from .storage import targets


class Monitor:
    def __init__(self, store, github):
        self.store, self.github = store, github
        self.states, self.errors, self.queue_errors = {}, {}, {}
        self.tracker = CompletionTracker()
        self.last_update = None
        self.candidates = {"mine": [], "review": [], "error": None}
        self.candidates_at = 0
        self.request_count = 0

    def workflow(self, repo):
        return next((r.get("workflow") for r in self.store.config["repos"] if r["repo"].lower() == repo.lower()), None)

    def base_target(self, repo, branch):
        return next((t for t in targets(self.store.config) if t.repo.lower() == repo.lower() and t.branch == branch),
                    Target(repo, branch, self.workflow(repo)))

    def refresh(self):
        self.store.reload_config()
        watched = {t.key: t for t in targets(self.store.config)}
        for key in set(self.tracker.seen) - set(watched):
            self.tracker.forget(key)
        queries = dict(watched)
        for pr in self.store.queue:
            if pr.base:
                target = self.base_target(pr.repo, pr.base)
                queries[target.key] = target
        self.states = {k: s for k, s in self.states.items() if k in queries}
        self.errors = {}
        self.queue_errors = {}
        branch_results, pr_results = {}, {}
        with ThreadPoolExecutor(max_workers=4) as pool:
            jobs = {pool.submit(self.github.runs, t): ("branch", key) for key, t in queries.items()}
            jobs.update({pool.submit(self.github.pull_request, pr.repo, pr.number): ("pr", pr.key)
                         for pr in self.store.queue})
            for future in as_completed(jobs):
                kind, key = jobs[future]
                try:
                    (branch_results if kind == "branch" else pr_results)[key] = future.result()
                except Exception as exc:
                    (self.errors if kind == "branch" else self.queue_errors)[key] = str(exc)
        self.request_count = len(queries) + len(self.store.queue)
        branch_notices, queue_notices = [], []
        for key, runs in branch_results.items():
            self.states[key] = BranchStatus.from_runs(runs)
            if key in watched:
                for run, previous in self.tracker.completions(key, runs):
                    notice = branch_notice(watched[key], run, previous)
                    if notice:
                        branch_notices.append(notice)
        retained = []
        for pr in self.store.queue:
            result = pr_results.get(pr.key)
            if result and result["state"] != "OPEN":
                continue
            retained.append(pr)
            if result:
                base = self.base_target(pr.repo, result["baseRefName"])
                base_status = self.states.get(base.key) if base.key in branch_results else None
                notice = pr.update(result, base_status, self.workflow(pr.repo))
                if notice:
                    queue_notices.append(notice)
                if base.key in self.errors:
                    self.queue_errors[pr.key] = "branch de destino: " + self.errors[base.key]
        self.store.queue = retained
        if pr_results:
            self.store.save_queue()
        if branch_results or pr_results or not queries and not self.store.queue:
            self.last_update = time.time()
        suppressed = {n.place for n in queue_notices if n.place}
        return [n for n in branch_notices if n.place not in suppressed and
                (n.kind != "passed" or self.store.settings["notifyPassed"])] + queue_notices

    def refresh_candidates(self):
        if time.monotonic() - self.candidates_at < 60:
            return
        try:
            with ThreadPoolExecutor(max_workers=2) as pool:
                mine, review = pool.submit(self.github.candidates), pool.submit(self.github.candidates, True)
                own, requested = mine.result(), review.result()
            own_ids = {(p["repository"]["nameWithOwner"].lower(), p["number"]) for p in own}
            requested = [p for p in requested if (p["repository"]["nameWithOwner"].lower(), p["number"]) not in own_ids]
            self.candidates = {"mine": own, "review": requested, "error": None}
        except Exception as exc:
            self.candidates["error"] = str(exc)
        self.candidates_at = time.monotonic()

    def add_repo(self, repo, branches, workflow):
        # Do not overwrite a hand edit made while the dialog was open.
        self.store.reload_config()
        if self.store.config_error:
            raise ValueError(self.store.config_error)
        entry = self.github.validate_repo(repo, branches, workflow)
        config = copy.deepcopy(self.store.config)
        config["repos"] = [r for r in config["repos"] if r["repo"].lower() != entry["repo"].lower()]
        config["repos"].append(entry)
        self.store.save_config(config)

    def remove_repo(self, repo):
        self.store.reload_config()
        if self.store.config_error:
            raise ValueError(self.store.config_error)
        config = copy.deepcopy(self.store.config)
        config["repos"] = [r for r in config["repos"] if r["repo"].lower() != repo.lower()]
        self.store.save_config(config)

    def add_pr(self, repo, number):
        if self.store.queue_error:
            raise ValueError(self.store.queue_error)
        if any(pr.key == (repo.lower(), number) for pr in self.store.queue):
            return
        data = self.github.pull_request(repo, number)
        if data["state"] != "OPEN":
            raise ValueError("Esse PR já foi mergeado ou fechado.")
        base = self.base_target(repo, data["baseRefName"])
        status = BranchStatus.from_runs(self.github.runs(base))
        pr = QueuedPR(repo, number)
        pr.update(data, status, self.workflow(repo), initial=True)
        self.store.queue.append(pr)
        try:
            self.store.save_queue()
        except OSError:
            self.store.queue.remove(pr)
            raise

    def remove_prs(self, keys):
        if self.store.queue_error:
            raise ValueError(self.store.queue_error)
        previous = self.store.queue
        self.store.queue = [pr for pr in previous if pr.key not in keys]
        try:
            self.store.save_queue()
        except OSError:
            self.store.queue = previous
            raise

    def snapshot(self):
        watched = targets(self.store.config)
        statuses = [self.states.get(t.key) for t in watched]
        current_queue = [pr for pr in self.store.queue if pr.key not in self.queue_errors]
        base_statuses = [self.states.get(self.base_target(pr.repo, pr.base).key)
                         for pr in current_queue if pr.base]
        signals = [pr.signal for pr in self.store.queue if pr.key not in self.queue_errors]
        signal = next((s for s in ("ready", "failed", "running") if s in signals), None)
        running = any(s and s.active for s in statuses) or any(pr.checks in ACTIVE or pr.base_busy for pr in self.store.queue)
        return copy.deepcopy({"config": self.store.config, "targets": watched, "states": self.states,
                              "errors": self.errors, "queue": self.store.queue, "queue_errors": self.queue_errors,
                              "settings": self.store.settings, "candidates": self.candidates,
                              "config_error": self.store.config_error, "queue_error": self.store.queue_error,
                              "settings_error": self.store.settings_error,
                              "overall": overall(statuses), "signal": signal, "last_update": self.last_update,
                              "icon_state": tray_state(overall(statuses + base_statuses), current_queue),
                              "interval": polling_interval(self.request_count, running)})
