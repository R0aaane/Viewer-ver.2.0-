import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
import zipfile

from tool.host_release_agent import Agent, extract_bundle, read_json
from tool.package_host_release import package


class BundleTests(unittest.TestCase):
    def bundle(self, extra=None, **changes):
        files = {"server/main.py": b"", "build/web/index.html": b"web", "requirements.txt": b""}
        files.update(extra or {})
        manifest = dict(format=1, dataEpoch=1, python="3.10", platform="win-amd64",
                        version="1.0.0+1", files={p: hashlib.sha256(v).hexdigest() for p, v in files.items()})
        manifest.update(changes)
        result = io.BytesIO()
        with zipfile.ZipFile(result, "w") as archive:
            for name, data in files.items():
                archive.writestr(name, data)
            archive.writestr("release.json", json.dumps(manifest))
        result.seek(0)
        return result

    def test_valid_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            extract_bundle(self.bundle(), directory)
            self.assertEqual((Path(directory) / "build/web/index.html").read_bytes(), b"web")

    def test_rejects_data_settings_and_traversal(self):
        for name in ("../outside", "data/metadata.db", "server/.env", "server/a.py:stream", "server/../a.py", "server/a.py.",
                     "server/CON.py", "server//main.py", "server/./main.py"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(ValueError):
                    extract_bundle(self.bundle({name: b"bad"}), directory)

    def test_rejects_checksum_and_incompatible_migration(self):
        for changes in ({"files": {}}, {"dataEpoch": 2}, {"python": "3.12"}):
            with tempfile.TemporaryDirectory() as directory, self.assertRaises(ValueError):
                extract_bundle(self.bundle(**changes), directory)

    def test_packager_excludes_local_data(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("server/main.py", "server/.env", "server/tests/test_secret.py", "data/metadata.db",
                         "build/web/index.html", "wheelhouse/example.whl", "assets/config/tag_aliases.json", "requirements.txt"):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("test", encoding="utf-8")
            (root / "pubspec.yaml").write_text("version: 1.2.3+4\n", encoding="utf-8")
            archive = package(root, root / "dist", "abc")
            with zipfile.ZipFile(archive) as bundle:
                self.assertNotIn("server/.env", bundle.namelist())
                self.assertNotIn("data/metadata.db", bundle.namelist())
                self.assertNotIn("server/tests/test_secret.py", bundle.namelist())


class ActivationTests(unittest.TestCase):
    def agent(self, directory):
        agent = Agent.__new__(Agent)
        agent.root = Path(directory)
        agent.state_path = agent.root / "state.json"
        agent.state = {"current": "old", "tag": "host-1-1"}
        agent.process = Mock()
        agent.stop_file = agent.root / "stop"
        agent.stop = Mock()
        agent.start = Mock()
        agent.status = Mock()
        agent.backup = Mock()
        return agent

    def test_failed_activation_restores_previous_and_quarantines_candidate(self):
        with tempfile.TemporaryDirectory() as directory:
            agent = self.agent(directory)
            agent.start.side_effect = [RuntimeError("unhealthy"), None]
            with self.assertRaises(RuntimeError):
                agent.activate("new", "host-2-1")
            self.assertEqual([call.args[0] for call in agent.start.call_args_list], ["new", "old"])
            self.assertEqual(read_json(agent.state_path)["current"], "old")
            self.assertEqual(agent.state["failedTag"], "host-2-1")
            self.assertNotIn("pending", agent.state)

    def test_success_commits_only_after_health(self):
        with tempfile.TemporaryDirectory() as directory:
            agent = self.agent(directory)
            def check_pending(name):
                self.assertEqual(read_json(agent.state_path)["current"], "old")
                self.assertEqual(read_json(agent.state_path)["pending"], "new")
            agent.start.side_effect = check_pending
            agent.activate("new", "host-2-1")
            self.assertEqual(agent.state["current"], "new")
            self.assertEqual(agent.state["previous"], "old")

    def test_shutdown_timeout_never_starts_competing_server(self):
        with tempfile.TemporaryDirectory() as directory:
            agent = self.agent(directory)
            agent.stop.side_effect = RuntimeError("busy")
            with self.assertRaises(RuntimeError):
                agent.activate("new", "host-2-1")
            agent.start.assert_not_called()
            self.assertEqual(read_json(agent.state_path)["current"], "old")

    def test_preparation_failure_does_not_stop_current(self):
        with tempfile.TemporaryDirectory() as directory:
            agent = self.agent(directory)
            agent.latest = Mock(return_value={"tag_name": "host-2-1"})
            agent.prepare = Mock(side_effect=ValueError("bad checksum"))
            with self.assertRaises(ValueError):
                agent.tick()
            agent.stop.assert_not_called()

    def test_failed_release_is_not_retried(self):
        with tempfile.TemporaryDirectory() as directory:
            agent = self.agent(directory)
            agent.state["failedTag"] = "host-2-1"
            agent.latest = Mock(return_value={"tag_name": "host-2-1"})
            agent.prepare = Mock()
            agent.tick()
            agent.prepare.assert_not_called()

    def test_late_process_failure_rolls_back(self):
        with tempfile.TemporaryDirectory() as directory:
            agent = self.agent(directory)
            agent.releases = Path(directory)
            (agent.releases / "new").mkdir()
            (agent.releases / "new/release.json").write_text('{"version":"2"}', encoding="utf-8")
            agent.state = {"current": "new", "previous": "old", "tag": "host-2-1"}
            agent.port = 12345
            agent.env = {}
            agent.healthy = Mock(return_value=False)
            agent.process.poll.return_value = 1
            agent.supervise()
            agent.start.assert_called_once_with("old")
            self.assertEqual(agent.state["current"], "old")
            self.assertEqual(agent.state["failedTag"], "host-2-1")

    def test_interrupted_drain_recovers_before_polling(self):
        with tempfile.TemporaryDirectory() as directory:
            agent = self.agent(directory)
            agent.state.update(pending="new", pendingTag="host-2-1")
            agent.process.poll.return_value = 0
            agent.latest = Mock(return_value={"tag_name": "host-2-1"})
            agent.tick()
            agent.start.assert_called_once_with("old")
            self.assertNotIn("pending", agent.state)


class ManagedUpdateTests(unittest.TestCase):
    def test_existing_api_queues_release_check_without_powershell(self):
        from server.services.host_update_service import start_host_update
        with tempfile.TemporaryDirectory() as directory:
            request = Path(directory) / "update.request"
            with patch.dict("os.environ", {"MEDIA_SERVER_RELEASE_MANAGED": "true", "MEDIA_SERVER_RELEASE_REQUEST": str(request)}), patch("subprocess.Popen") as popen:
                self.assertEqual(start_host_update(None, Path(directory))["state"], "queued")
                self.assertTrue(request.exists())
                popen.assert_not_called()


if __name__ == "__main__":
    unittest.main()
