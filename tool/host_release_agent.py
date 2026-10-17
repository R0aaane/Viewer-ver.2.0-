"""Build-free Windows host supervisor. Configuration and data live outside releases."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import json
import logging
import os
from pathlib import Path, PurePosixPath
import re
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid
import zipfile

LOG = logging.getLogger("host-release")


def release_order(tag):
    if not isinstance(tag, str) or not re.fullmatch(r"host-\d+-\d+", tag):
        raise ValueError("Invalid release tag")
    return tuple(map(int, tag.split("-")[1:]))


def file_hash(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def inbox_release(path):
    release = read_json(path)
    release_order(release.get("tag_name"))
    if path.name != release["tag_name"] + ".json":
        raise ValueError("Release descriptor name mismatch")
    if not re.fullmatch(r"[0-9a-f]{40,64}", release.get("revision", "")):
        raise ValueError("Invalid source revision")
    if not re.fullmatch(r"[0-9a-f]{64}", release.get("sha256", "")):
        raise ValueError("Invalid archive checksum")
    if not re.fullmatch(re.escape(release["tag_name"]) + r"-[0-9a-f]{32}\.zip", release.get("archive", "")):
        raise ValueError("Invalid archive name")
    return release


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def write_json(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


@contextmanager
def exclusive_lock(path):
    import msvcrt
    with open(path, "a+b") as handle:
        handle.seek(0)
        handle.write(b"0")
        handle.flush()
        handle.seek(0)
        msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
        try:
            yield
        finally:
            handle.seek(0)
            msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)


def extract_bundle(archive, destination):
    """Reject traversal, symlinks, configuration, duplicate names and corrupt files."""
    destination = Path(destination)
    with zipfile.ZipFile(archive) as bundle:
        names = bundle.namelist()
        if len({name.casefold() for name in names}) != len(names):
            raise ValueError("Duplicate bundle paths")
        manifest = json.loads(bundle.read("release.json"))
        runtime = f"{sys.version_info.major}.{sys.version_info.minor}"
        if (manifest.get("format"), manifest.get("dataEpoch"), manifest.get("python"), manifest.get("platform")) != (1, 1, runtime, "win-amd64"):
            raise ValueError("Incompatible release: requires manual migration")
        if set(names) != set(manifest["files"]) | {"release.json"}:
            raise ValueError("Bundle manifest mismatch")
        for item in bundle.infolist():
            name = item.filename
            path = PurePosixPath(name)
            if (path.is_absolute() or path.as_posix() != name or ".." in path.parts or "\\" in name or ":" in name
                    or any(part.endswith((".", " ")) for part in path.parts)
                    or any(re.fullmatch(r"(?i)(con|prn|aux|nul|com[1-9]|lpt[1-9])", part.split(".")[0]) for part in path.parts)
                    or (item.external_attr >> 16) & 0o170000 == 0o120000):
                raise ValueError("Unsafe bundle path")
            allowed = (name in {"release.json", "requirements.txt", "assets/config/tag_aliases.json"}
                       or name.startswith("server/") and name.endswith(".py")
                       or name.startswith("build/web/")
                       or name.startswith("wheelhouse/") and name.endswith(".whl"))
            if not allowed:
                raise ValueError("Unexpected bundle file")
            data = bundle.read(item)
            if name != "release.json" and hashlib.sha256(data).hexdigest() != manifest["files"][name]:
                raise ValueError("File checksum mismatch")
            target = destination.joinpath(*path.parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
    for required in ("server/main.py", "build/web/index.html", "requirements.txt"):
        if not (destination / required).is_file():
            raise ValueError("Incomplete bundle")
    return manifest


class Agent:
    def __init__(self, config_path):
        self.config_path = Path(config_path).resolve()
        self.config = read_json(self.config_path)
        self.root = self.config_path.parent
        # Fixed inbox: transferred files never choose a data/configuration path.
        self.inbox = self.root / "inbox"
        self.inbox.mkdir(exist_ok=True)
        self.report_dir = self.root / "report"
        self.report_dir.mkdir(exist_ok=True)
        self.releases = self.root / "releases"
        self.releases.mkdir(exist_ok=True)
        self.state_path = self.root / "state.json"
        self.state = read_json(self.state_path) if self.state_path.exists() else {}
        self.process = None
        self.stop_file = self.root / "server.stop"
        self.env = os.environ.copy()
        env_path = Path(self.config["envFile"])
        if not env_path.is_absolute():
            raise ValueError("envFile must be absolute")
        for line in env_path.read_text(encoding="utf-8-sig").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                self.env[key.strip()] = value.strip().strip("\"'")
        # No implicit new data directories during migration.
        for key in ("MEDIA_SERVER_DATA_DIR", "MEDIA_SERVER_DB_PATH", "MEDIA_SERVER_THUMBS_DIR",
                    "MEDIA_SERVER_XVIEWER_SAVED_IMAGES_DIR"):
            path = Path(self.env.get(key, ""))
            if not path.is_absolute() or any(path.resolve().is_relative_to(p.resolve()) for p in (self.releases, self.inbox, self.report_dir)):
                raise ValueError(f"{key} must be an absolute path outside releases/inbox/report")
        roots = self.env.get("MEDIA_SERVER_MEDIA_ROOTS", "").split(";")
        if not roots or any(not Path(p).is_absolute() or any(Path(p).resolve().is_relative_to(d.resolve()) for d in (self.releases, self.inbox, self.report_dir)) for p in roots):
            raise ValueError("Explicit absolute media roots outside releases are required")
        self.data = Path(self.env["MEDIA_SERVER_DATA_DIR"])
        self.data.mkdir(parents=True, exist_ok=True)
        self.env["MEDIA_SERVER_RELEASE_MANAGED"] = "true"
        self.env["MEDIA_SERVER_RELEASE_REQUEST"] = str(self.root / "update.request")
        self.env.setdefault("MEDIA_SERVER_HOST", "0.0.0.0")
        self.env.setdefault("MEDIA_SERVER_PORT", "8000")
        self.port = int(self.env["MEDIA_SERVER_PORT"])

    def save(self):
        write_json(self.state_path, self.state)

    def status(self, state, message):
        self.state["lastStatus"] = {"state": state, "message": message}
        self.save()
        self.publish_status()
        LOG.info("%s: %s", state, message)

    def publish_status(self):
        current = self.state.get("current")
        manifest = read_json(self.releases / current / "release.json") if current else {}
        payload = {
            **self.state.get("lastStatus", {"state": "idle", "message": "Waiting for a direct delivery"}),
            "activeRevision": manifest.get("revision"),
            "activeVersion": manifest.get("version"),
            "attemptedTag": self.state.get("attemptedTag"),
            "attemptedRevision": self.state.get("attemptedRevision"),
            "serverRunning": self.process is not None and self.process.poll() is None,
            "pid": os.getpid(),
            "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        write_json(self.data / "host_update_status.json", payload)
        write_json(self.report_dir / "status.json", payload)

    def latest(self):
        releases = []
        for path in self.inbox.glob("host-*.json"):
            try:
                releases.append(inbox_release(path))
            except (ValueError, KeyError, OSError):
                LOG.exception("Rejected inbox descriptor: %s", path.name)
        return max(releases, key=lambda r: release_order(r["tag_name"]), default=None)

    def prepare(self, release):
        archive = self.inbox / release["archive"]
        if archive.is_symlink() or not archive.resolve().is_relative_to(self.inbox.resolve()):
            raise ValueError("Archive escapes inbox")
        if file_hash(archive) != release["sha256"]:
            raise ValueError("Archive checksum mismatch")
        stage = self.state.get("staged", {})
        if stage.get("tag") != release["tag_name"] or stage.get("sha256") != release["sha256"]:
            stage = {"tag": release["tag_name"], "sha256": release["sha256"],
                     "target": release["tag_name"] + "-" + uuid.uuid4().hex[:8]}
            self.state["staged"] = stage
            self.save()
        target = self.releases / stage["target"]
        target.mkdir(exist_ok=True)
        if not stage.get("unpacked"):
            manifest = extract_bundle(archive, target)
            if manifest.get("revision") != release["revision"]:
                raise ValueError("Source revision mismatch")
            stage["unpacked"] = True
            self.save()
        if not stage.get("installed"):
            subprocess.run([sys.executable, "-m", "venv", str(target / ".venv")], check=True)
            python = target / ".venv/Scripts/python.exe"
            subprocess.run([str(python), "-m", "pip", "install", "--no-index", "--only-binary=:all:",
                            "--find-links", str(target / "wheelhouse"), "-r", str(target / "requirements.txt")], check=True)
            stage["installed"] = True
            self.save()
        self.smoke(target)
        return target.name

    def launch(self, target, env, stop):
        env = dict(env, PYTHONPATH=str(target), PYTHONNOUSERSITE="1", PYTHONDONTWRITEBYTECODE="1",
                   MEDIA_SERVER_VERSION=read_json(target / "release.json")["version"],
                   MEDIA_SERVER_WEB_BUILD_DIR=str(target / "build/web"), PDF_VIEWER_STOP_FILE=str(stop),
                   PDF_VIEWER_RUNTIME_LOCK=str(stop.with_suffix(".lock")))
        stop.unlink(missing_ok=True)
        with (self.root / "server.log").open("ab") as output:
            return subprocess.Popen([str(target / ".venv/Scripts/python.exe"), str(self.root / "host_runtime.py")],
                                    cwd=target, env=env, stdout=output, stderr=output,
                                    creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)

    def healthy(self, process, port, version, token):
        if process.poll() is not None:
            return False
        try:
            headers = {"Authorization": f"Bearer {token}"} if token else {}
            req = urllib.request.Request(f"http://127.0.0.1:{port}/health", headers=headers)
            with urllib.request.urlopen(req, timeout=3) as response:
                if json.load(response)["version"] != version:
                    return False
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/version.json", timeout=3) as response:
                web = json.load(response)
                return f'{web["version"]}+{web["build_number"]}' == version
        except Exception:
            return False

    def wait_healthy(self, process, port, version, token):
        deadline = time.monotonic() + self.config.get("healthTimeoutSeconds", 120)
        consecutive = 0
        while time.monotonic() < deadline and process.poll() is None:
            consecutive = consecutive + 1 if self.healthy(process, port, version, token) else 0
            if consecutive >= 3:
                return
            time.sleep(1)
        raise RuntimeError("Release health check failed")

    def stop(self, process, stop):
        stop.touch()
        try:
            process.wait(timeout=90)
        except subprocess.TimeoutExpired:
            # Do not start a competing writer or forcibly terminate active work.
            raise RuntimeError("Graceful shutdown timed out; refusing to start another server")

    def smoke(self, target):
        with tempfile.TemporaryDirectory(dir=self.root) as temporary:
            directory = Path(temporary)
            with socket.socket() as sock:
                sock.bind(("127.0.0.1", 0))
                port = sock.getsockname()[1]
            env = dict(self.env, MEDIA_SERVER_HOST="127.0.0.1", MEDIA_SERVER_PORT=str(port),
                       MEDIA_SERVER_DATA_DIR=str(directory), MEDIA_SERVER_DB_PATH=str(directory / "test.db"),
                       MEDIA_SERVER_THUMBS_DIR=str(directory / "thumbs"), MEDIA_SERVER_MEDIA_ROOTS="",
                       MEDIA_SERVER_XVIEWER_SAVED_IMAGES_DIR=str(directory / "images"), MEDIA_SERVER_STARTUP_RESCAN="false")
            # Exercise startup against a consistent copy, never against the live DB.
            source = Path(self.env["MEDIA_SERVER_DB_PATH"])
            if source.is_file():
                with sqlite3.connect(source.as_uri() + "?mode=ro", uri=True) as src, sqlite3.connect(directory / "test.db") as dst:
                    src.backup(dst)
            stop = directory / "stop"
            process = self.launch(target, env, stop)
            try:
                self.wait_healthy(process, port, read_json(target / "release.json")["version"], env.get("MEDIA_SERVER_AUTH_TOKEN", ""))
            finally:
                self.stop(process, stop)

    def start(self, name):
        target = self.releases / name
        self.process = self.launch(target, self.env, self.stop_file)
        self.wait_healthy(self.process, self.port, read_json(target / "release.json")["version"], self.env.get("MEDIA_SERVER_AUTH_TOKEN", ""))

    def activate(self, name, tag):
        previous = self.state.get("current")
        self.state.update(pending=name, pendingTag=tag)
        self.save()  # Recover the previous confirmed release after power loss.
        if self.process:
            self.stop(self.process, self.stop_file)
        try:
            self.start(name)
        except Exception:
            if self.process:
                self.stop(self.process, self.stop_file)
                self.process = None
            self.state["failedTag"] = tag
            self.state.pop("pending", None)
            self.state.pop("pendingTag", None)
            self.save()
            if previous:
                self.start(previous)
            self.status("failed", "Candidate failed; previous confirmed release restored" if previous else "Initial release failed")
            raise
        self.state.update(previous=previous, current=name, tag=tag)
        self.state.pop("pending", None)
        self.state.pop("pendingTag", None)
        self.save()
        self.status("succeeded", f"Activated {tag}")

    def tick(self):
        if self.state.get("pending"):
            # A timed-out drain must finish before retrying any switch.
            if self.process and self.process.poll() is None:
                return
            self.process = None
            self.state["failedTag"] = self.state.pop("pendingTag")
            self.state.pop("pending")
            self.save()
            if self.state.get("current"):
                self.start(self.state["current"])
        release = self.latest()
        if not release or release["tag_name"] in {self.state.get("tag"), self.state.get("failedTag")}:
            return
        if self.state.get("tag") and release_order(release["tag_name"]) <= release_order(self.state["tag"]):
            return
        self.state.update(attemptedTag=release["tag_name"], attemptedRevision=release.get("revision"))
        self.status("running", "Preparing release while current server remains available")
        name = self.prepare(release)
        if (self.root / "agent.stop").exists():
            return
        self.activate(name, release["tag_name"])

    def supervise(self):
        if not self.process or self.state.get("pending"):
            return
        current = self.state["current"]
        version = read_json(self.releases / current / "release.json")["version"]
        if self.healthy(self.process, self.port, version, self.env.get("MEDIA_SERVER_AUTH_TOKEN", "")):
            self.health_failures = 0
            return
        self.health_failures = getattr(self, "health_failures", 0) + 1
        if self.process.poll() is None and self.health_failures < 3:
            return
        previous = self.state.get("previous")
        self.stop(self.process, self.stop_file)
        if previous:
            self.start(previous)
            self.state.update(current=previous, previous=None, failedTag=self.state["tag"])
            self.save()
            self.status("failed", "Health regression; restored previous release")
        else:
            self.start(current)
        self.health_failures = 0

    def run(self):
        agent_stop = self.root / "agent.stop"
        agent_stop.unlink(missing_ok=True)
        # An orphan from a previous agent receives the same graceful stop request.
        self.stop_file.touch()
        deadline = time.monotonic() + 100
        while True:
            runtime_free = False
            try:
                with exclusive_lock(self.stop_file.with_suffix(".lock")):
                    runtime_free = True
            except OSError:
                pass
            with socket.socket() as sock:
                occupied = sock.connect_ex(("127.0.0.1", self.port)) == 0
            if not occupied and runtime_free:
                break
            if time.monotonic() > deadline:
                raise RuntimeError("Port still occupied; stop the old updater/server before migration")
            time.sleep(1)
        if self.state.get("pending"):
            self.state["failedTag"] = self.state.pop("pendingTag")
            self.state.pop("pending")
            self.save()
        try:
            if self.state.get("current"):
                try:
                    self.start(self.state["current"])
                except Exception:
                    self.health_failures = 3
                    self.supervise()
            while not agent_stop.exists():
                try:
                    self.supervise()
                    self.tick()
                except Exception:
                    LOG.exception("Update failed; retry on next poll")
                    self.status("failed", "Update failed; see agent.log")
                self.publish_status()
                for _ in range(max(5, self.config.get("pollSeconds", 15))):
                    if agent_stop.exists():
                        break
                    request = self.root / "update.request"
                    if request.exists():
                        request.unlink(missing_ok=True)
                        break
                    time.sleep(1)
        finally:
            if self.process:
                self.stop(self.process, self.stop_file)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--stop", action="store_true", help="Request graceful shutdown of the agent and its API")
    args = parser.parse_args()
    config = Path(args.config).resolve()
    if args.stop:
        (config.parent / "agent.stop").touch()
        sys.exit(0)
    logging.basicConfig(filename=config.parent / "agent.log", level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s", encoding="utf-8")
    with exclusive_lock(config.parent / "agent.lock"):
        Agent(config).run()
