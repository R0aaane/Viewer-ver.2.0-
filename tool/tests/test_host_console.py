import json
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import urllib.request
import urllib.error
import zipfile
from http.server import ThreadingHTTPServer

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from host_console import Console, Policy, handler, release_view


class ConsoleTests(unittest.TestCase):
    def test_release_tracks_new_versions_and_rollback(self):
        for version in ("1.0.219+229", "1.0.220+230", "1.0.219+229"):
            name, build = version.split("+")
            result = release_view({}, {"state": "succeeded", "activeVersion": version},
                                  version, {"version": name, "build_number": build}, 1)
            self.assertEqual(result["phase"], "current")
            self.assertTrue(result["aligned"])

    def test_update_missing_probes_mismatch_and_stale(self):
        report = {"state": "running", "activeVersion": "1+1"}
        self.assertEqual(release_view({}, report, None, None, 1)["phase"], "updating")
        report["state"] = "succeeded"
        self.assertEqual(release_view({"pending": "next"}, report, None, None, 1)["phase"], "updating")
        self.assertEqual(release_view({}, report, "1+1", {"version": "2", "build_number": "2"}, 1)["phase"], "mismatch")
        self.assertEqual(release_view({}, report, "1+1", {"version": "1+1"}, 90)["phase"], "unknown")
        for invalid in (None, {}, [], "not-json-object"):
            self.assertEqual(release_view({}, report, "1+1", invalid, 1)["phase"], "unavailable")

    def test_stale_report_blocks_restart(self):
        import os
        os.utime(self.root / "report/status.json", (0, 0))
        with patch("host_console.task_state", return_value="Running"), patch("host_console.powershell") as command:
            self.console.restart()
            command.assert_not_called()
        self.assertFalse((self.root / "agent.stop").exists())

    def test_control_queues_stop_and_rejects_duplicate(self):
        (self.root / "report/status.json").write_text('{"state":"idle","controlProtocol":1}', encoding="utf-8")
        with patch("host_console.task_state", return_value="Running"):
            self.console.request_control("stop")
            self.assertEqual(json.loads((self.root / "console.request.json").read_text(encoding="utf-8"))["action"], "stop")
            with self.assertRaises(ValueError):
                self.console.request_control("stop")

    def test_control_rejects_unknown_version_and_old_agent(self):
        with self.assertRaises(ValueError):
            self.console.request_control("stop")
        (self.root / "report/status.json").write_text('{"state":"idle","controlProtocol":1}', encoding="utf-8")
        with self.assertRaises(ValueError):
            self.console.request_control("start", "../invalid")
        self.assertFalse((self.root / "console.request.json").exists())

    def test_delivered_versions_can_be_selected(self):
        inbox = self.root / "inbox"
        inbox.mkdir()
        archive = "host-1-2-" + "a" * 32 + ".zip"
        with zipfile.ZipFile(inbox / archive, "w") as bundle:
            bundle.writestr("release.json", '{"version":"1.0.216+226"}')
        descriptor = {"tag_name":"host-1-2", "archive":archive, "revision":"a"*40, "sha256":"b"*64}
        (inbox / "host-1-2.json").write_text(json.dumps(descriptor), encoding="utf-8")
        self.assertEqual(self.console.available_releases()[0]["version"], "1.0.216+226")
        (self.root / "report/status.json").write_text('{"state":"idle","controlProtocol":1}', encoding="utf-8")
        with patch("host_console.task_state", return_value="Running"):
            self.console.request_control("start", "host-1-2")
        self.assertEqual(json.loads((self.root / "console.request.json").read_text(encoding="utf-8"))["tag"], "host-1-2")

    def test_policy_requires_continuous_overload_and_failure(self):
        policy = Policy()
        self.assertFalse(policy.due(0, False, 96, 50, []))
        self.assertFalse(policy.due(299, False, 96, 50, []))
        self.assertTrue(policy.due(300, False, 96, 50, []))
        self.assertFalse(policy.due(301, True, 99, 99, []))
        self.assertFalse(policy.due(302, False, 99, 99, []))
        self.assertFalse(policy.due(700, False, 50, 50, []))

    def test_policy_budget_and_cooldown(self):
        policy = Policy()
        policy.since = 0
        self.assertFalse(policy.due(3000, False, 99, 99, [2900]))
        self.assertFalse(policy.due(9000, False, 99, 99, [100, 200]))
        self.assertTrue(policy.due(90000, False, 99, 99, [100, 200]))
        self.assertFalse(policy.due(90001, False, None, 99, []))

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "host.env").write_text("MEDIA_SERVER_PORT=8090\n", encoding="utf-8")
        (self.root / "agent.json").write_text(json.dumps({"envFile": str(self.root / "host.env")}), encoding="utf-8")
        (self.root / "state.json").write_text('{"current":"example"}', encoding="utf-8")
        (self.root / "report").mkdir()
        (self.root / "report/status.json").write_text('{"state":"succeeded"}', encoding="utf-8")
        self.console = Console(self.root)

    def tearDown(self):
        self.temp.cleanup()

    def test_restart_skips_pending_update(self):
        (self.root / "state.json").write_text('{"pending":"new"}', encoding="utf-8")
        with patch("host_console.task_state", return_value="Running"), patch("host_console.powershell") as command:
            self.console.restart()
            command.assert_not_called()
        self.assertFalse((self.root / "agent.stop").exists())

    def test_restart_rate_limit_survives_restart(self):
        self.console.settings["attempts"] = [time.time()]
        from host_release_agent import write_json
        write_json(self.console.settings_path, self.console.settings)
        reloaded = Console(self.root)
        with patch("host_console.powershell") as command:
            reloaded.restart()
            command.assert_not_called()
        self.assertFalse((self.root / "agent.stop").exists())

    def test_restart_timeout_does_not_force_or_start(self):
        with patch("host_console.task_state", return_value="Running"), \
                patch("host_console.time.monotonic", side_effect=[0, 151]), \
                patch("host_console.powershell") as command:
            self.console.restart()
            command.assert_not_called()
        self.assertTrue((self.root / "agent.stop").exists())
        self.assertIn("タイムアウト", self.console.message)

    def test_restart_waits_for_release_then_starts(self):
        from contextlib import nullcontext
        with patch("host_console.task_state", side_effect=["Running", "Ready", "Running"]), \
                patch("host_console.exclusive_lock", side_effect=lambda _: nullcontext()) as locks, \
                patch("host_console.socket.socket") as sock, \
                patch.object(self.console, "probe", return_value=(True, {})), \
                patch("host_console.powershell") as command:
            sock.return_value.__enter__.return_value.connect_ex.return_value = 1
            self.console.restart()
            self.assertEqual(locks.call_count, 2)
            command.assert_called_once_with("Start-ScheduledTask -TaskName 'PdfViewerHostRelease'")
        self.assertIn("再起動・応答を確認", self.console.message)

    def test_stopped_agent_restarts_even_with_stale_running_report(self):
        import os
        from contextlib import nullcontext
        (self.root / "report/status.json").write_text('{"state":"running"}', encoding="utf-8")
        os.utime(self.root / "report/status.json", (0, 0))
        with patch("host_console.task_state", side_effect=["Ready", "Ready", "Running"]), \
                patch("host_console.exclusive_lock", side_effect=lambda _: nullcontext()), \
                patch("host_console.socket.socket") as sock, \
                patch.object(self.console, "probe", return_value=(True, {})), \
                patch("host_console.powershell") as command:
            sock.return_value.__enter__.return_value.connect_ex.return_value = 1
            self.console.restart()
            command.assert_called_once_with("Start-ScheduledTask -TaskName 'PdfViewerHostRelease'")
        self.assertFalse((self.root / "agent.stop").exists())

    def test_occupied_port_refuses_start(self):
        from contextlib import nullcontext
        with patch("host_console.task_state", side_effect=["Running", "Ready"]), \
                patch("host_console.exclusive_lock", side_effect=lambda _: nullcontext()), \
                patch("host_console.socket.socket") as sock, \
                patch("host_console.powershell") as command:
            sock.return_value.__enter__.return_value.connect_ex.return_value = 0
            self.console.restart()
            command.assert_not_called()
        self.assertIn("二重起動を拒否", self.console.message)

    def test_http_origin_and_token_checks(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), handler(self.console))
        self.console.origin = f"http://127.0.0.1:{server.server_port}"
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        def request(headers):
            return urllib.request.Request(self.console.origin + "/api/automatic/off", method="POST", headers=headers)
        try:
            for headers in ({}, {"Origin": "http://evil.invalid", "X-Console-Token": self.console.token},
                            {"Origin": self.console.origin, "X-Console-Token": "wrong"}):
                with self.assertRaises(urllib.error.HTTPError) as error:
                    urllib.request.urlopen(request(headers))
                self.assertEqual(error.exception.code, 403)
            with urllib.request.urlopen(request({"Origin": self.console.origin, "X-Console-Token": self.console.token})) as response:
                self.assertEqual(response.status, 202)
            self.assertFalse(self.console.settings["automatic"])
            with urllib.request.urlopen(self.console.origin + "/") as response:
                self.assertIn("管理コンソール", response.read().decode("utf-8"))
            with self.assertRaises(urllib.error.HTTPError):
                urllib.request.urlopen(urllib.request.Request(self.console.origin + "/", headers={"Host": "evil.invalid"}))
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    unittest.main()
