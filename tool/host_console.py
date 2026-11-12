"""Local-only operational console, independent of deployed application releases."""
import argparse
import ctypes
import json
import secrets
import socket
import subprocess
import threading
import time
import urllib.request
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from host_release_agent import exclusive_lock, inbox_release, release_order, read_json, write_json

VERSION = "1.2.1"
TASK = "PdfViewerHostRelease"
PS = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"


def powershell(script):
    result = subprocess.run([PS, "-NoProfile", "-NonInteractive", "-Command",
                             "$ErrorActionPreference='Stop'; " + script],
                            capture_output=True, timeout=20,
                            creationflags=subprocess.CREATE_NO_WINDOW)
    if result.returncode:
        raise RuntimeError("Windows task query/action failed")
    return result.stdout.decode("utf-8-sig").strip()


def task_state():
    return powershell(f"[string](Get-ScheduledTask -TaskName '{TASK}').State")


def release_view(state, report, api_version, web_version, report_age):
    """Treat preparation, switching and mismatched probes as separate states."""
    updating = bool(state.get("pending")) or report.get("state") == "running"
    web = None
    if isinstance(web_version, dict) and web_version.get("version"):
        web = str(web_version["version"])
        if "+" not in web and web_version.get("build_number") is not None:
            web += "+" + str(web_version["build_number"])
    expected = report.get("activeVersion")
    aligned = bool(expected and api_version == web == expected)
    phase = ("updating" if updating else "unknown" if report_age > 60 else
             "unavailable" if not api_version or not web else "current" if aligned else "mismatch")
    return {"phase": phase, "aligned": aligned, "webVersion": web,
            "expectedVersion": expected, "updating": updating}


class Metrics:
    def __init__(self):
        self.previous = None

    def sample(self):
        idle, kernel, user = (ctypes.c_ulonglong() for _ in range(3))
        if not ctypes.windll.kernel32.GetSystemTimes(ctypes.byref(idle), ctypes.byref(kernel), ctypes.byref(user)):
            raise OSError("GetSystemTimes failed")
        current = (idle.value, kernel.value + user.value)
        cpu = None
        if self.previous:
            elapsed = current[1] - self.previous[1]
            if elapsed > 0:
                cpu = round(100 * (1 - (current[0] - self.previous[0]) / elapsed), 1)
        self.previous = current
        class Memory(ctypes.Structure):
            _fields_ = [("length", ctypes.c_ulong), ("load", ctypes.c_ulong)] + [
                (name, ctypes.c_ulonglong) for name in ("total", "available", "page", "freepage", "virtual", "freevirtual", "extended")]
        memory = Memory()
        memory.length = ctypes.sizeof(memory)
        if not ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(memory)):
            raise OSError("GlobalMemoryStatusEx failed")
        return cpu, memory.load


class Policy:
    """Five continuous minutes of overload AND failed API; at most two/day."""
    def __init__(self):
        self.since = None

    def due(self, now, api_ok, cpu, memory, attempts):
        overloaded = cpu is not None and (cpu >= 95 or memory >= 95)
        if api_ok or not overloaded:
            self.since = None
            return False
        if self.since is None:
            self.since = now
        return (now - self.since >= 300 and
                (not attempts or now - attempts[-1] >= 1800) and
                sum(now - item < 86400 for item in attempts) < 2)


class Console:
    def __init__(self, root):
        self.root = root
        self.settings_path = root / "console-settings.json"
        self.settings = read_json(self.settings_path) if self.settings_path.exists() else {"automatic": True, "attempts": []}
        self.lock = threading.Lock()
        self.action_lock = threading.Lock()
        self.snapshot = {"message": "状態を取得しています"}
        self.message = "監視開始"
        self.policy = Policy()
        self.metrics = Metrics()
        self.history = []
        self.release_identity = None
        self.settle_until = time.time() + 300
        self.token = secrets.token_urlsafe(32)
        self.origin = "http://127.0.0.1:18091"
        config = read_json(root / "agent.json")
        env = {}
        for line in Path(config["envFile"]).read_text(encoding="utf-8-sig").splitlines():
            if line.strip() and not line.lstrip().startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                env[key.strip()] = value.strip().strip('\"').strip("'")
        self.port = int(env.get("MEDIA_SERVER_PORT", "8090"))
        self.auth = env.get("MEDIA_SERVER_AUTH_TOKEN", "")

    def event(self, message):
        self.message = message
        with (self.root / "console-events.jsonl").open("a", encoding="utf-8") as stream:
            stream.write(json.dumps({"time": time.time(), "message": message}, ensure_ascii=False) + "\n")

    def probe(self, path):
        headers = {"Cache-Control": "no-cache"}
        if self.auth:
            headers["Authorization"] = "Bearer " + self.auth
        request = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}", headers=headers)
        try:
            with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=5) as response:
                data = response.read(65536)
                if path == "/":
                    return True, "HTML" if b"<html" in data.lower() else "unexpected"
                parsed = json.loads(data)
                return isinstance(parsed, dict), parsed
        except Exception:
            return False, None

    def available_releases(self):
        releases = []
        for path in (self.root / "inbox").glob("host-*.json"):
            try:
                item = inbox_release(path)
                if (self.root / "inbox" / item["archive"]).is_file():
                    with zipfile.ZipFile(self.root / "inbox" / item["archive"]) as archive:
                        if archive.getinfo("release.json").file_size > 1048576:
                            continue
                        manifest = json.loads(archive.read("release.json"))
                    releases.append({"tag": item["tag_name"], "version": manifest.get("version"),
                                     "revision": item["revision"]})
            except (ValueError, KeyError, OSError, zipfile.BadZipFile):
                continue
        return sorted(releases, key=lambda item: release_order(item["tag"]), reverse=True)

    def request_control(self, action, tag=None):
        with self.action_lock:
            report = read_json(self.root / "report/status.json")
            state = read_json(self.root / "state.json")
            if report.get("controlProtocol") != 1:
                raise ValueError("更新エージェントを新版へ更新してください")
            if (state.get("pending") or report.get("state") == "running" or
                    (self.root / "console.request.json").exists()):
                raise ValueError("配布適用・操作中です。完了後に操作してください")
            if action == "start" and tag not in {r["tag"] for r in self.available_releases()}:
                raise ValueError("配布済みのバージョンを選択してください")
            task = task_state()
            if task not in ("Ready", "Running"):
                raise ValueError("更新タスクを起動できません")
            write_json(self.root / "console.request.json", {"action": action, "tag": tag})
            (self.root / "update.request").touch()
            if task == "Ready":
                powershell(f"Start-ScheduledTask -TaskName '{TASK}'")
            self.event("停止を要求しました" if action == "stop" else f"{tag} の適用・起動を要求しました")

    def restart(self):
        if not self.action_lock.acquire(blocking=False):
            return
        try:
            now = time.time()
            with self.lock:
                attempts = self.settings["attempts"]
                if attempts and now - attempts[-1] < 1800:
                    raise RuntimeError("再起動間隔は30分必要です")
                if sum(now - item < 86400 for item in attempts) >= 2:
                    raise RuntimeError("24時間の再起動上限2回に達しました")
            state = read_json(self.root / "state.json")
            report = read_json(self.root / "report/status.json")
            task = task_state()
            if task not in ("Running", "Ready"):
                raise RuntimeError("更新タスクを起動できません。タスク設定を確認してください")
            if task == "Running" and time.time() - (self.root / "report/status.json").stat().st_mtime > 60:
                raise RuntimeError("更新状態が古いため再起動を見送ります")
            if task == "Running" and (state.get("pending") or (self.root / "console.request.json").exists() or report.get("state") not in ("succeeded", "failed", "idle")):
                raise RuntimeError("更新処理中のため再起動を見送ります")
            with self.lock:
                self.settings["attempts"] = [item for item in attempts if now - item < 86400] + [now]
                write_json(self.settings_path, self.settings)
            if task == "Running":
                self.event("API・更新エージェントへ正常停止を要求")
                (self.root / "agent.stop").touch()
            else:
                self.event("停止した更新エージェントの再起動を準備しています")
            deadline = time.monotonic() + 150
            while time.monotonic() < deadline:
                if task_state() == "Ready":
                    try:
                        with exclusive_lock(self.root / "agent.lock"), exclusive_lock(self.root / "server.lock"):
                            with socket.socket() as sock:
                                sock.settimeout(1)
                                if sock.connect_ex(("127.0.0.1", self.port)) == 0:
                                    raise RuntimeError("APIポート使用中。二重起動を拒否")
                        break
                    except OSError:
                        pass
                time.sleep(3)
            else:
                raise RuntimeError("正常停止の確認がタイムアウト。強制終了せず手動確認を待ちます")
            powershell(f"Start-ScheduledTask -TaskName '{TASK}'")
            deadline = time.monotonic() + 150
            while time.monotonic() < deadline:
                if task_state() == "Running" and self.probe("/health")[0] and self.probe("/")[0]:
                    self.event("API/Webの再起動・応答を確認")
                    return
                time.sleep(5)
            raise RuntimeError("再起動後の応答待ちタイムアウト。手動確認が必要です")
        except Exception as exc:
            self.event(str(exc) if isinstance(exc, RuntimeError) else "再起動処理に失敗。手動確認が必要です")
        finally:
            self.action_lock.release()

    def monitor(self):
        while True:
            try:
                cpu, memory = self.metrics.sample()
                api_ok, health = self.probe("/health")
                web_ok, html = self.probe("/")
                version_ok, web_version = self.probe("/version.json")
                report = read_json(self.root / "report/status.json")
                state = read_json(self.root / "state.json")
                task = task_state()
                now = time.time()
                age = max(0, round(now - (self.root / "report/status.json").stat().st_mtime))
                release = release_view(state, report, health.get("version") if api_ok else None,
                                       web_version if version_ok else None, age)
                identity = (state.get("current"), report.get("activeRevision"))
                if identity != self.release_identity or release["updating"]:
                    self.settle_until = now + 300
                    self.release_identity = identity
                queued = (self.root / "console.request.json").exists()
                protected = release["updating"] or queued or state.get("paused", False) or age > 60 or now < self.settle_until
                self.history = (self.history + [{"time": now, "cpu": cpu, "memory": memory}])[-60:]
                with self.lock:
                    self.snapshot = {"consoleVersion": VERSION, "checkedAt": now,
                        "api": api_ok, "web": web_ok and html == "HTML", "task": task,
                        "apiVersion": health.get("version") if api_ok else None,
                        "webVersion": web_version if version_ok else None,
                        "cpu": cpu, "memory": memory, "automatic": self.settings["automatic"],
                        "report": {key: report.get(key) for key in ("state", "message", "activeRevision", "activeVersion", "pid", "updatedAt", "controlProtocol", "attemptedTag")},
                        "releases": self.available_releases(), "selectedTag": state.get("selectedTag"),
                        "paused": state.get("paused", False), "queued": queued,
                        "reportAge": age, "release": release, "history": self.history,
                        "webUrl": f"http://127.0.0.1:{self.port}/", "protected": protected,
                        "settleSeconds": max(0, round(self.settle_until - now)),
                        "message": self.message, "busy": self.action_lock.locked()}
                    due = self.policy.due(now, api_ok or protected, cpu, memory, self.settings["attempts"])
                    automatic = self.settings["automatic"]
                if automatic and due and not self.action_lock.locked():
                    threading.Thread(target=self.restart, daemon=True).start()
            except Exception:
                with self.lock:
                    self.snapshot = {"checkedAt": time.time(), "error": "監視情報を取得できません。タスク権限・設定を確認してください"}
                self.policy.since = None
            time.sleep(15)


def handler(console):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def reply(self, code, payload, content_type="application/json"):
            data = payload.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", content_type + "; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Frame-Options", "DENY")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(data)

        def allowed(self):
            return self.headers.get("Host") == console.origin.removeprefix("http://")

        def do_GET(self):
            if not self.allowed():
                return self.reply(403, "{}")
            if self.path == "/":
                page = Path(__file__).with_suffix(".html").read_text(encoding="utf-8")
                return self.reply(200, page.replace("__TOKEN__", console.token), "text/html")
            if self.path == "/api/status":
                with console.lock:
                    snapshot = dict(console.snapshot, queued=(console.root / "console.request.json").exists(),
                                    busy=console.action_lock.locked(), message=console.message)
                    return self.reply(200, json.dumps(snapshot, ensure_ascii=False))
            if self.path == "/api/session":
                return self.reply(200, json.dumps({"token": console.token}))
            self.reply(404, "{}")

        def do_POST(self):
            if (not self.allowed() or self.headers.get("Origin") != console.origin or
                    not secrets.compare_digest(self.headers.get("X-Console-Token", ""), console.token)):
                return self.reply(403, "{}")
            if self.path in ("/api/web/start", "/api/web/stop"):
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    if not 0 <= length <= 4096:
                        raise ValueError("要求サイズが不正です")
                    body = json.loads(self.rfile.read(length) or b"{}")
                    if not isinstance(body, dict):
                        raise ValueError("要求形式が不正です")
                    console.request_control(self.path.rsplit("/", 1)[-1], body.get("tag"))
                except ValueError as exc:
                    return self.reply(409, json.dumps({"error": str(exc)}, ensure_ascii=False))
                except Exception:
                    return self.reply(500, json.dumps({"error": "操作に失敗しました。更新タスクを確認してください"}, ensure_ascii=False))
            elif self.path == "/api/restart":
                threading.Thread(target=console.restart, daemon=True).start()
            elif self.path in ("/api/automatic/on", "/api/automatic/off"):
                with console.lock:
                    console.settings["automatic"] = self.path.endswith("/on")
                    write_json(console.settings_path, console.settings)
                    console.snapshot["automatic"] = console.settings["automatic"]
            else:
                return self.reply(404, "{}")
            self.reply(202, "{}")
    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    with exclusive_lock(args.root / "console.lock"):
        console = Console(args.root)
        server = ThreadingHTTPServer(("127.0.0.1", 18091), handler(console))
        stop = args.root / "console.stop"
        stop.unlink(missing_ok=True)
        def watch_stop():
            while not stop.exists():
                time.sleep(1)
            # Finish any recovery already in progress before closing this console.
            with console.action_lock:
                server.shutdown()
        threading.Thread(target=watch_stop, daemon=True).start()
        threading.Thread(target=console.monitor, daemon=True).start()
        try:
            server.serve_forever()
        finally:
            server.server_close()


if __name__ == "__main__":
    main()
