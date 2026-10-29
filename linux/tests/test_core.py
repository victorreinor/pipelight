import unittest

from pipelight.core import (BranchStatus, CompletionTracker, QueuedPR, Run, Target, branch_notice,
                           overall, parse_branches, parse_pr, parse_repo, polling_interval,
                           summarize_checks, tray_state)


def run(number=1, state="success", workflow="CI", attempt=1):
    return Run(number, attempt, workflow, "feat: example", "in_progress" if state == "running" else "completed",
               "" if state == "running" else state, 100, 110, 200, "https://github.com/acme/api/actions/runs/1")


def job(state="SUCCESS", started="2026-10-29T10:00:00Z", workflow="CI"):
    return {"__typename": "CheckRun", "name": "build", "workflowName": workflow,
            "status": "IN_PROGRESS" if state == "running" else "COMPLETED",
            "conclusion": "" if state == "running" else state, "startedAt": started}


def pr(state="SUCCESS", sha="a", base="main"):
    return {"number": 42, "title": "feat: example", "state": "OPEN", "url": "https://github.com/acme/api/pull/42",
            "author": {"login": "ana"}, "headRefOid": sha, "baseRefName": base, "statusCheckRollup": [job(state)]}


class InputTests(unittest.TestCase):
    def test_repository_formats(self):
        for value in ["acme/api", "git@github.com:acme/api.git", "ssh://git@github.com/acme/api.git",
                      "https://github.com/acme/api/tree/main", "github.com/acme/api"]:
            with self.subTest(value=value):
                self.assertEqual(parse_repo(value), "acme/api")

    def test_rejects_foreign_hosts_and_paths(self):
        for value in ["https://evil.example/acme/api", "--help", "../api", "acme/..", "acme/$(command)"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                parse_repo(value)

    def test_pr_in_message(self):
        for value in ["acme/api#42", "veja https://github.com/acme/api/pull/42/files quando puder"]:
            self.assertEqual(parse_pr(value), ("acme/api", 42))

    def test_invalid_pr(self):
        for value in ["#42", "https://github.com/acme/api/issues/42", "https://fakegithub.com/acme/api/pull/42", "acme/api#0"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                parse_pr(value)

    def test_branches_and_action_url(self):
        self.assertEqual(parse_branches("main, homolog main"), ["main", "homolog"])
        self.assertIn("branch%3Afeat%2Fa%26b", Target("acme/api", "feat/a&b").url)


class StatusTests(unittest.TestCase):
    def test_old_failure_does_not_override_fixed_workflow(self):
        self.assertEqual(BranchStatus.from_runs([run(2), run(1, "failure")]).state, "passed")

    def test_other_workflow_failure_is_visible(self):
        self.assertEqual(BranchStatus.from_runs([run(2), run(1, "failure", "Deploy")]).state, "failed")

    def test_running_has_priority_and_previous(self):
        status = BranchStatus.from_runs([run(3, "running"), run(2, "failure")])
        self.assertEqual(status.state, "running")
        self.assertEqual(status.previous.id, 2)

    def test_skipped_does_not_hide_result(self):
        self.assertEqual(BranchStatus.from_runs([run(2, "skipped"), run(1, "failure")]).state, "failed")

    def test_overall(self):
        busy, broken = BranchStatus.from_runs([run(state="running")]), BranchStatus.from_runs([run(state="failure")])
        self.assertEqual(overall([busy, broken]), "running-failed")
        self.assertEqual(overall([]), "empty")
        self.assertEqual(overall([None]), "unknown")
        self.assertEqual(overall([BranchStatus.from_runs([run(state="cancelled")])]), "passed")

    def test_api_decoding_keeps_attempt_and_null_dates(self):
        result = Run.from_api({"id": 7, "run_attempt": 2, "status": "queued", "created_at": "2026-10-29T10:00:00Z",
                               "run_started_at": "0001-01-01T00:00:00Z", "conclusion": None})
        self.assertEqual(result.key, (7, 2))
        self.assertEqual(result.started, result.created)
        self.assertTrue(result.active)

    def test_first_load_is_silent_and_completion_not_repeated(self):
        tracker = CompletionTracker()
        self.assertEqual(tracker.completions("t", [run(2, "running"), run(1)]), [])
        self.assertEqual([r.id for r, _ in tracker.completions("t", [run(2), run(1)])], [2])
        self.assertEqual(tracker.completions("t", [run(2), run(1)]), [])

    def test_between_polls_and_reruns_are_announced(self):
        tracker = CompletionTracker()
        tracker.completions("t", [run(1)])
        self.assertEqual(len(tracker.completions("t", [run(2), run(1)])), 1)
        self.assertEqual(len(tracker.completions("t", [run(2, attempt=2), run(1)])), 1)

    def test_removing_and_readding_target_is_silent(self):
        tracker = CompletionTracker()
        tracker.completions("t", [run(1)])
        tracker.forget("t")
        self.assertEqual(tracker.completions("t", [run(2)]), [])

    def test_notice_recovery_and_silence_for_cancelled(self):
        target = Target("acme/api", "main")
        notice = branch_notice(target, run(2), run(1, "failure"))
        self.assertEqual(notice.kind, "fixed")
        self.assertIn("voltou a passar", notice.title)
        self.assertFalse(notice.sound)
        self.assertTrue(branch_notice(target, run(state="failure"), None).sound)
        self.assertIsNone(branch_notice(target, run(state="cancelled"), None))

    def test_polling_budget(self):
        self.assertEqual(polling_interval(1, True), 15)
        self.assertEqual(polling_interval(1, False), 30)
        self.assertGreaterEqual(polling_interval(100, True), 180)

    def test_queue_running_overrides_ready_prs_and_keeps_failure_color(self):
        ready = QueuedPR("acme/api", 1, checks="passed", base_busy=False)
        busy = QueuedPR("acme/api", 2, checks="running", base_busy=True)
        broken = QueuedPR("acme/api", 3, checks="failed", base_busy=False)
        self.assertEqual(tray_state("empty", [ready, busy]), "running")
        self.assertEqual(tray_state("empty", [ready, busy, broken]), "running-failed")
        self.assertEqual(tray_state("empty", [ready, broken]), "failed")
        self.assertEqual(tray_state("empty", [ready]), "ready")


class CheckTests(unittest.TestCase):
    def test_running_beats_failed(self):
        self.assertEqual(summarize_checks([job("FAILURE"), {**job("running"), "name": "test"}])[0], "running")

    def test_workflow_filter_and_filename_fallback(self):
        jobs = [job(), job("FAILURE", workflow="Lint")]
        self.assertEqual(summarize_checks(jobs, "ci")[0], "passed")
        self.assertEqual(summarize_checks(jobs, "ci.yml")[0], "failed")
        self.assertIsNone(summarize_checks(jobs, "Deploy")[0])

    def test_latest_attempt_of_job_wins(self):
        self.assertEqual(summarize_checks([job("FAILURE", "2026-10-29T09:00:00Z"), job()])[0], "passed")

    def test_external_status_and_cancelled(self):
        self.assertEqual(summarize_checks([{"__typename": "StatusContext", "context": "CodeBuild", "state": "PENDING"}])[0], "running")
        self.assertEqual(summarize_checks([job("CANCELLED")])[0], "cancelled")
        self.assertIsNone(summarize_checks(None)[0])


class QueueTests(unittest.TestCase):
    def setUp(self):
        self.busy = BranchStatus.from_runs([run(state="running")])
        self.free = BranchStatus.from_runs([run()])
        self.broken = BranchStatus.from_runs([run(state="failure")])

    def queued(self, state="SUCCESS", base=None):
        queued = QueuedPR("acme/api", 42)
        self.assertIsNone(queued.update(pr(state), base, initial=True))
        return queued

    def test_add_to_free_branch_is_silent_with_ready_badge(self):
        q = self.queued(base=self.free)
        self.assertEqual(q.signal, "ready")
        self.assertIsNone(q.update(pr(), self.free))

    def test_wait_for_base_even_if_pr_ci_passes(self):
        q = self.queued("running", self.busy)
        self.assertIsNone(q.update(pr(), self.busy))
        self.assertIsNone(q.signal)
        notice = q.update(pr(), self.free)
        self.assertTrue(notice.queue)
        self.assertTrue(notice.sound)
        self.assertEqual(notice.place, ("acme/api", "main"))
        self.assertEqual(q.signal, "ready")
        self.assertIsNone(q.update(pr(), self.free))

    def test_free_with_checks_running_then_ready(self):
        q = self.queued("running", self.busy)
        self.assertIn("ainda rodando", q.update(pr("running"), self.free).body)
        self.assertEqual(q.signal, "running")
        self.assertIn("pronto para mergear", q.update(pr(), self.free).title)

    def test_broken_deploy_still_notifies(self):
        q = self.queued(base=self.busy)
        self.assertEqual(q.update(pr(), self.broken).kind, "failed")

    def test_new_push_and_recovery(self):
        q = self.queued("FAILURE", self.free)
        self.assertIsNone(q.update(pr("running", "b"), self.free))
        notice = q.update(pr("SUCCESS", "b"), self.free)
        self.assertEqual(notice.kind, "fixed")
        self.assertIsNone(q.update(pr("SUCCESS", "b"), self.free))

    def test_retarget_or_unknown_base_does_not_announce_history(self):
        q = self.queued(base=self.busy)
        self.assertIsNone(q.update(pr(base="homolog"), self.free))
        q = self.queued()
        self.assertIsNone(q.update(pr(), self.free))
        self.assertEqual(q.signal, "ready")

    def test_base_query_failure_cannot_announce_ready(self):
        q = self.queued("running", self.free)
        self.assertIsNone(q.update(pr(), None))
        self.assertIsNotNone(q.update(pr(), self.free))

    def test_new_deploy_clears_badge(self):
        q = self.queued(base=self.free)
        self.assertIsNone(q.update(pr(), self.busy))
        self.assertIsNone(q.signal)
        self.assertIsNotNone(q.update(pr(), self.free))
