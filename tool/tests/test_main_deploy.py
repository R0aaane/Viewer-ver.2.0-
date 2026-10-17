from datetime import datetime, timezone
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
import zipfile

from tool.deploy_transport import SftpTransport, quoted_path
from tool.host_release_agent import Agent, inbox_release, read_json, write_json, file_hash
from tool.main_pc_deploy import Builder, extract_source

SHA = "a" * 40
NEXT = "b" * 40


class TransportTests(unittest.TestCase):
    def transport(self, root):
        transport = SftpTransport.__new__(SftpTransport)
        transport.workdir = root
        transport.config = {"inbox": "/D:/host/inbox"}
        transport.read_remote_json = Mock(side_effect=RuntimeError("not found"))
        transport.batch = Mock()
        return transport

    def test_publish_ready_descriptor_is_last_and_archive_is_immutable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "host.zip"
            archive.write_bytes(b"bundle")
            transport = self.transport(root)
            transport.publish(archive, SHA, "host-1-1")
            commands = transport.batch.call_args.args[0]
            self.assertTrue(commands[0].startswith('put '))
            self.assertTrue(commands[1].startswith('rename '))
            self.assertTrue(commands[2].startswith('put '))
            self.assertTrue(commands[3].endswith('/host-1-1.json"'))
            self.assertNotIn("rm ", "\n".join(commands))

    def test_retry_after_lost_ack_does_not_upload_again(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "host.zip"
            archive.write_bytes(b"bundle")
            transport = self.transport(root)
            transport.read_remote_json.side_effect = None
            transport.read_remote_json.return_value = {"revision": SHA, "sha256": file_hash(archive)}
            transport.publish(archive, SHA, "host-1-1")
            transport.batch.assert_not_called()

    def test_batch_command_injection_is_rejected(self):
        for value in ('/folder\nrm /data', '/folder"', '/folder/*', '/folder/[a]'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                quoted_path(value)


class InboxTests(unittest.TestCase):
    def test_only_completed_valid_descriptors_are_seen(self):
        with tempfile.TemporaryDirectory() as directory:
            agent = Agent.__new__(Agent)
            agent.inbox = Path(directory)
            descriptor = {"tag_name": "host-2-1", "revision": SHA, "sha256": "0" * 64,
                          "archive": "host-2-1-" + "a" * 32 + ".zip"}
            write_json(agent.inbox / "host-2-1.json.part", descriptor)
            self.assertIsNone(agent.latest())
            write_json(agent.inbox / "host-2-1.json", descriptor)
            self.assertEqual(agent.latest(), descriptor)
            descriptor["archive"] = "../data/metadata.db"
            write_json(agent.inbox / "host-2-1.json", descriptor)
            with self.assertRaises(ValueError):
                inbox_release(agent.inbox / "host-2-1.json")

    def test_source_archive_cannot_escape_build_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = io.BytesIO()
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr("../metadata.db", "bad")
            archive.seek(0)
            with self.assertRaises(ValueError):
                extract_source(archive, Path(directory))


class BuilderTests(unittest.TestCase):
    def test_unconfigured_transport_builds_and_can_be_enabled_after_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = {"repository": str(Path.cwd()), "remote": "test", "branch": "main",
                      "python": sys.executable, "transport": None}
            path = root / "config.json"
            write_json(path, config)
            builder = Builder(path)
            builder.remote_head = Mock(return_value=SHA)
            builder.build = Mock(return_value=root / "host.zip")
            builder.tick()
            self.assertEqual(builder.state["phase"], "awaiting_transport")
            builder.build.assert_called_once_with(SHA)
            config["transport"] = {"target": "deploy@100.100.18.16"}
            write_json(path, config)
            with patch("tool.main_pc_deploy.SftpTransport") as transport:
                resumed = Builder(path)
                resumed.refresh_host = Mock()
                resumed.remote_head = Mock(return_value=SHA)
                resumed.build = Mock(return_value=root / "host.zip")
                resumed.tick()
                transport.return_value.publish.assert_called_once()
                self.assertEqual(resumed.state["phase"], "awaiting_apply")

    def test_invalid_transport_does_not_block_build_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            write_json(path, {"repository": str(Path.cwd()), "remote": "test", "branch": "main",
                              "python": sys.executable, "transport": {"target": "deploy@100.100.18.16"}})
            self.assertIsNone(Builder(path).transport)

    def builder(self, directory):
        builder = Builder.__new__(Builder)
        builder.root = Path(directory)
        builder.state_path = builder.root / "main-state.json"
        builder.state = {}
        builder.jobs = builder.root / "jobs"
        builder.jobs.mkdir()
        builder.config = {"python": sys.executable}
        builder.repo = Path.cwd()
        builder.remote = "test"
        builder.branch = "feature_hitomi"
        builder.transport = Mock()
        builder.refresh_host = Mock()
        builder.remote_head = Mock(return_value=SHA)
        builder.build = Mock(return_value=builder.root / "host.zip")
        return builder

    def test_same_remote_commit_is_sent_once(self):
        with tempfile.TemporaryDirectory() as directory:
            builder = self.builder(directory)
            builder.tick()
            builder.tick()
            builder.build.assert_called_once_with(SHA)
            builder.transport.publish.assert_called_once()
            self.assertEqual(builder.state["phase"], "awaiting_apply")

    def test_network_failure_retries_same_delivery_after_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            builder = self.builder(directory)
            builder.transport.publish.side_effect = RuntimeError("offline")
            with self.assertRaises(RuntimeError):
                builder.tick()
            tag = builder.state["delivery"]["tag"]
            builder.state = read_json(builder.state_path)
            builder.transport.publish.side_effect = None
            builder.tick()
            self.assertEqual(builder.state["delivery"]["tag"], tag)
            self.assertTrue(builder.state["delivery"]["sent"])

    def test_new_push_during_build_is_not_deployed(self):
        with tempfile.TemporaryDirectory() as directory:
            builder = self.builder(directory)
            builder.remote_head.side_effect = [SHA, NEXT]
            builder.tick()
            builder.transport.publish.assert_not_called()
            self.assertEqual(builder.state["phase"], "superseded")

    def test_successful_cached_build_does_not_run_build_commands(self):
        with tempfile.TemporaryDirectory() as directory:
            builder = self.builder(directory)
            job = builder.jobs / SHA
            (job / "dist").mkdir(parents=True)
            archive = job / "dist/host.zip"
            archive.write_bytes(b"completed")
            write_json(job / "build.json", {"built": True, "sha256": file_hash(archive)})
            builder.command = Mock()
            self.assertEqual(Builder.build(builder, SHA), archive)
            builder.command.assert_not_called()

    def test_completed_stages_survive_failure_without_rebuilding_web(self):
        with tempfile.TemporaryDirectory() as directory:
            builder = self.builder(directory)
            builder.config["buildWindows"] = True
            job = builder.jobs / SHA
            source = job / "source"
            source.mkdir(parents=True)
            (source / "pubspec.yaml").write_text("version: 1.0.0+1\n", encoding="utf-8")
            completed = ["venv", "wheels", "backend-dependencies", "test-dependencies", "backend-tests", "update-tests", "pub", "generated", "flutter-tests", "web"]
            write_json(job / "build.json", {"source": str(source), "completed": completed})
            builder.command = Mock(side_effect=["[3,10,64]", RuntimeError("windows failed")])
            with self.assertRaisesRegex(RuntimeError, "windows failed"):
                Builder.build(builder, SHA)
            self.assertEqual(read_json(job / "build.json")["completed"], completed)
            commands = [c.args[0] for c in builder.command.call_args_list]
            self.assertEqual(commands[-1][:3], ["flutter", "build", "windows"])
            self.assertFalse(any(c[:3] == ["flutter", "build", "web"] for c in commands))

    def test_only_remote_reference_is_considered_not_local_head(self):
        with tempfile.TemporaryDirectory() as directory:
            builder = self.builder(directory)
            builder.command = Mock(return_value=f"{SHA}\trefs/heads/feature_hitomi")
            self.assertEqual(Builder.remote_head(builder), SHA)
            self.assertEqual(builder.command.call_args.args[0], ["git", "ls-remote", "--exit-code", "test", "refs/heads/feature_hitomi"])

    def test_host_confirmation_and_rollback_are_distinct_from_transfer(self):
        with tempfile.TemporaryDirectory() as directory:
            builder = self.builder(directory)
            builder.state = {"delivery": {"tag": "host-1-1", "revision": SHA, "sent": True}, "phase": "awaiting_apply"}
            builder.transport.read_status.return_value = {
                "attemptedTag": "host-1-1", "activeRevision": SHA, "serverRunning": True,
                "state": "succeeded", "updatedAt": datetime.now(timezone.utc).isoformat(),
            }
            Builder.refresh_host(builder)
            self.assertEqual(builder.state["phase"], "applied")
            builder.transport.read_status.return_value.update(activeRevision=NEXT, state="failed")
            Builder.refresh_host(builder)
            self.assertEqual(builder.state["phase"], "apply_failed")

    def test_stale_host_status_never_confirms_application(self):
        with tempfile.TemporaryDirectory() as directory:
            builder = self.builder(directory)
            builder.state = {"delivery": {"tag": "host-1-1", "revision": SHA, "sent": True}, "phase": "awaiting_apply"}
            builder.transport.read_status.return_value = {
                "attemptedTag": "host-1-1", "activeRevision": SHA, "serverRunning": True,
                "state": "succeeded", "updatedAt": "2000-01-01T00:00:00Z",
            }
            Builder.refresh_host(builder)
            self.assertEqual(builder.state["phase"], "awaiting_apply")
            self.assertIn("stale", builder.state["hostError"])

    def test_snapshot_uses_pushed_commit_without_touching_local_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo = root / "development"
            repo.mkdir()

            def git(*args):
                result = subprocess.run(["git", *args], cwd=repo, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                return result.stdout.strip()

            git("init", "-b", "feature_hitomi")
            (repo / "pubspec.yaml").write_text("version: 1.0.0+1\n", encoding="utf-8")
            (repo / "requirements.txt").write_text("fastapi\n", encoding="utf-8")
            (repo / "data").mkdir()
            (repo / "data/private.db").write_bytes(b"do not export")
            git("add", ".")
            git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "-m", "source")
            remote = root / "remote.git"
            git("clone", "--bare", str(repo), str(remote))
            git("remote", "add", "test", str(remote))
            (repo / "pubspec.yaml").write_text("version: 9.0.0+9\n", encoding="utf-8")
            builder = self.builder(root)
            builder.repo = repo
            builder.env = os.environ.copy()
            builder.command = lambda *args, **kwargs: Builder.command(builder, *args, **kwargs)
            revision = Builder.remote_head(builder)
            job = builder.jobs / revision
            job.mkdir()
            source = builder.snapshot(revision, job)
            self.assertEqual((source / "pubspec.yaml").read_text(encoding="utf-8").strip(), "version: 1.0.0+1")
            self.assertFalse((source / "data").exists())
            self.assertTrue((source / "requirements.txt").is_file())
            self.assertEqual((repo / "pubspec.yaml").read_text(encoding="utf-8").strip(), "version: 9.0.0+9")


@unittest.skipUnless(os.name == "nt", "Windows job containment")
class ProcessJobTests(unittest.TestCase):
    def test_exit_of_builder_terminates_only_its_child(self):
        code = "from tool.windows_process_job import contain_children; import subprocess,sys; contain_children(); p=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); print(p.pid,flush=True)"
        result = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        pid = int(result.stdout.strip())
        import ctypes
        from ctypes import wintypes
        api = ctypes.WinDLL("kernel32", use_last_error=True)
        api.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        api.OpenProcess.restype = wintypes.HANDLE
        api.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        api.CloseHandle.argtypes = [wintypes.HANDLE]
        handle = api.OpenProcess(0x100000, False, pid)
        if handle:
            try:
                self.assertEqual(api.WaitForSingleObject(handle, 5000), 0)
            finally:
                api.CloseHandle(handle)


if __name__ == "__main__":
    unittest.main()
