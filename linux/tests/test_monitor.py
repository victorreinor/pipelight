import json
from pathlib import Path
import tempfile
import unittest

from pipelight.core import Target
from pipelight.demo import DemoGitHub
from pipelight.monitor import Monitor
from pipelight.storage import Store, atomic_json, validate_config
from test_core import pr, run


class FakeGitHub(DemoGitHub):
    def __init__(self):
        self.current_runs = [run()]
        self.current_pr = pr()
        self.fail = False

    def runs(self, target):
        if self.fail:
            raise RuntimeError("sem conexão com o GitHub")
        return self.current_runs

    def pull_request(self, repo, number):
        return self.current_pr


class StoreTests(unittest.TestCase):
    def test_invalid_config_keeps_last_good_and_file(self):
        with tempfile.TemporaryDirectory() as temp:
            store = Store(temp)
            store.save_config({"repos": [{"repo": "acme/api", "branches": ["main"]}]})
            path = Path(temp) / "config.json"
            path.write_text("{bad json")
            store.reload_config()
            self.assertEqual(store.config["repos"][0]["repo"], "acme/api")
            self.assertIsNotNone(store.config_error)
            self.assertEqual(path.read_text(), "{bad json")

    def test_readonly_does_not_create_directory_or_save(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "absent"
            store = Store(path, readonly=True)
            store.save_config({"repos": []})
            store.save_queue()
            self.assertFalse(path.exists())

    def test_invalid_queue_is_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "queue.json"
            path.write_text("{bad json")
            store = Store(temp)
            self.assertIsNotNone(store.queue_error)
            with self.assertRaises(ValueError):
                store.save_queue()
            self.assertEqual(path.read_text(), "{bad json")

    def test_atomic_write_permissions_and_validation(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "config.json"
            atomic_json(path, {"repos": []})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(path.read_text()), {"repos": []})
        for config in [{"repos": "bad"}, {"repos": [{"repo": "acme/api", "branches": "main"}]},
                       {"repos": [{"repo": "acme/api", "workflow": 42}]}]:
            with self.assertRaises(ValueError):
                validate_config(config)


class MonitorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = Store(self.temp.name)
        self.store.save_config({"repos": [{"repo": "acme/api", "branches": ["main"]}]})
        self.github = FakeGitHub()
        self.monitor = Monitor(self.store, self.github)

    def test_real_refresh_flow_and_recovery(self):
        self.assertEqual(self.monitor.refresh(), [])
        self.github.current_runs = [run(2, "failure"), run(1)]
        notices = self.monitor.refresh()
        self.assertEqual(len(notices), 1)
        self.assertEqual(notices[0].kind, "failed")
        self.assertEqual(self.monitor.refresh(), [])
        self.github.current_runs = [run(3), run(2, "failure")]
        self.assertEqual(self.monitor.refresh()[0].kind, "fixed")

    def test_network_error_keeps_last_status(self):
        self.monitor.refresh()
        self.github.fail = True
        self.assertEqual(self.monitor.refresh(), [])
        snapshot = self.monitor.snapshot()
        key = Target("acme/api", "main").key
        self.assertEqual(snapshot["states"][key].state, "passed")
        self.assertIn(key, snapshot["errors"])

    def test_disabled_success_notices_do_not_disable_failure(self):
        self.store.settings["notifyPassed"] = False
        self.monitor.refresh()
        self.github.current_runs = [run(2), run(1)]
        self.assertEqual(self.monitor.refresh(), [])
        self.github.current_runs = [run(3, "failure"), run(2)]
        self.assertEqual(len(self.monitor.refresh()), 1)

    def test_queue_notification_suppresses_duplicate_branch_notice(self):
        self.github.current_runs = [run(2, "running"), run(1)]
        self.monitor.add_pr("acme/api", 42)
        self.monitor.refresh()
        self.github.current_runs = [run(2), run(1)]
        notices = self.monitor.refresh()
        self.assertEqual(len(notices), 1)
        self.assertTrue(notices[0].queue)
        self.assertEqual(self.monitor.snapshot()["signal"], "ready")

    def test_merged_pr_leaves_queue_and_disk(self):
        self.monitor.add_pr("acme/api", 42)
        self.github.current_pr["state"] = "MERGED"
        self.monitor.refresh()
        self.assertEqual(self.store.queue, [])
        self.assertEqual(json.loads((self.store.directory / "queue.json").read_text()), [])

    def test_network_failure_hides_queue_badge(self):
        self.monitor.add_pr("acme/api", 42)
        self.monitor.refresh()
        self.github.fail = True
        self.monitor.refresh()
        self.assertIsNone(self.monitor.snapshot()["signal"])

    def test_queue_roundtrip(self):
        self.monitor.add_pr("acme/api", 42)
        restored = Store(self.temp.name)
        self.assertEqual(restored.queue, self.store.queue)

    def test_pr_only_setup_updates_the_primary_icon(self):
        self.store.save_config({"repos": []})
        self.github.current_pr = pr("running")
        self.monitor.add_pr("acme/api", 42)
        self.monitor.refresh()
        self.assertEqual(self.monitor.snapshot()["icon_state"], "running")
        self.github.current_pr = pr()
        self.monitor.refresh()
        self.assertEqual(self.monitor.snapshot()["icon_state"], "ready")
        self.github.current_pr = pr("FAILURE")
        self.monitor.refresh()
        self.assertEqual(self.monitor.snapshot()["icon_state"], "failed")

    def test_queued_pr_base_deploy_controls_the_primary_icon(self):
        self.store.save_config({"repos": []})
        self.github.current_runs = [run(state="running")]
        self.monitor.add_pr("acme/api", 42)
        self.monitor.refresh()
        self.assertEqual(self.monitor.snapshot()["icon_state"], "running")
        self.github.current_runs = [run(state="failure")]
        self.monitor.refresh()
        self.assertEqual(self.monitor.snapshot()["icon_state"], "failed")

    def test_snapshot_is_detached_from_worker_state(self):
        self.monitor.refresh()
        snap = self.monitor.snapshot()
        snap["config"]["repos"].clear()
        self.assertEqual(len(self.store.config["repos"]), 1)

    def test_config_edit_is_not_overwritten(self):
        path = self.store.directory / "config.json"
        path.write_text("bad")
        with self.assertRaises(ValueError):
            self.monitor.add_repo("acme/web", ["main"], None)
        self.assertEqual(path.read_text(), "bad")

    def test_add_default_branch_and_candidates(self):
        self.monitor.add_repo("acme/web", [], None)
        self.assertEqual(self.store.config["repos"][-1]["branches"], ["main"])
        self.monitor.refresh_candidates()
        self.assertEqual(len(self.monitor.candidates["mine"]), 1)
        self.assertEqual(len(self.monitor.candidates["review"]), 1)


if __name__ == "__main__":
    unittest.main()
