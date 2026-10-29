"""Fictional fixtures for offline UI verification; never touch a user's configuration."""

import time

from .core import Run


class DemoGitHub:
    def runs(self, target):
        now = time.time()
        busy = target.branch == "homolog"
        return [Run(42 if busy else 41, workflow="CI", title="feat: acompanhar o deploy",
                    status="in_progress" if busy else "completed", conclusion="" if busy else "success",
                    created=now - 540, started=now - 540, updated=now - 120,
                    url=f"https://github.com/{target.repo}/actions/runs/41")]

    def pull_request(self, repo, number):
        return {"number": number, "title": "feat: nova vitrine", "state": "OPEN", "author": {"login": "ana"},
                "url": f"https://github.com/{repo}/pull/{number}", "baseRefName": "main", "headRefOid": "demo-sha",
                "statusCheckRollup": [{"__typename": "CheckRun", "name": "build", "workflowName": "CI",
                                       "status": "COMPLETED", "conclusion": "SUCCESS"}]}

    def validate_repo(self, repo, branches, workflow):
        return {"repo": repo, "branches": branches or ["main"], "workflow": workflow}

    def candidates(self, review=False):
        return [{"number": 43 if review else 42, "title": "feat: nova vitrine", "repository": {"nameWithOwner": "acme/api"}}]
