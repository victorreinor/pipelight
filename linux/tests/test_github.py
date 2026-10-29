import json
import subprocess
import unittest
from unittest.mock import patch

from pipelight.core import Target
from pipelight.github import GitHub, GitHubError


class GitHubTests(unittest.TestCase):
    def test_old_gh_uses_api_and_preserves_attempt(self):
        response = {"workflow_runs": [{"id": 1, "run_attempt": 3, "status": "completed", "conclusion": "success"}]}
        with patch("pipelight.github.subprocess.run", return_value=subprocess.CompletedProcess([], 0, json.dumps(response), "")) as call:
            runs = GitHub("/usr/bin/gh").runs(Target("acme/api", "feature/a&b"))
        self.assertEqual(runs[0].attempt, 3)
        args = call.call_args.args[0]
        self.assertEqual(args[:4], ["/usr/bin/gh", "api", "--hostname", "github.com"])
        self.assertIn("branch=feature%2Fa%26b", args[-1])
        self.assertNotIn("shell", call.call_args.kwargs)
        self.assertEqual(call.call_args.kwargs["timeout"], 30)

    def test_named_workflow_resolves_once_and_cache_is_reused(self):
        github = GitHub("gh")
        workflows = json.dumps({"workflows": [{"id": 9, "name": "CI"}]})
        with patch.object(github, "call", return_value=workflows) as call:
            self.assertEqual(github.workflow_id("acme/api", "CI"), "9")
            self.assertEqual(github.workflow_id("acme/api", "ci"), "9")
        self.assertEqual(call.call_count, 1)

    def test_workflow_pagination(self):
        github = GitHub("gh")
        with patch.object(github, "call", return_value='{"workflows":[]}\n{"workflows":[{"id":9,"name":"CI"}]}'):
            self.assertEqual(github.workflow_id("acme/api", "CI"), "9")

    def test_timeout_becomes_actionable_error(self):
        with patch("pipelight.github.subprocess.run", side_effect=subprocess.TimeoutExpired("gh", 30)):
            with self.assertRaisesRegex(GitHubError, "30 segundos"):
                GitHub("gh").call("auth", "status")

    def test_api_error_and_invalid_json(self):
        for result, message in [(subprocess.CompletedProcess([], 1, "", "HTTP 401 authentication"), "gh sem login"),
                                (subprocess.CompletedProcess([], 0, "not json", ""), "resposta inválida")]:
            with patch("pipelight.github.subprocess.run", return_value=result):
                with self.assertRaisesRegex(GitHubError, message):
                    GitHub("gh").call("api", "user")
