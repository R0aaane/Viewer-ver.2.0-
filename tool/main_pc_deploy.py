"""Watch the remote branch, build exact commits, and deliver resumable host updates."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import logging
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import time
import uuid
import zipfile

try:
    from .deploy_transport import SftpTransport
    from .host_release_agent import exclusive_lock, file_hash, read_json, write_json
    from .package_host_release import package
    from .windows_process_job import contain_children
except ImportError:
    from deploy_transport import SftpTransport
    from host_release_agent import exclusive_lock, file_hash, read_json, write_json
    from package_host_release import package
    from windows_process_job import contain_children

LOG = logging.getLogger("main-deploy")
SOURCE_PATHS = {"pubspec.yaml", "pubspec.lock", "lib", "web", "server", "assets", "test", "tool",
                "third_party", "windows", "env.json", "analysis_options.yaml", "requirements.txt"}


def extract_source(archive, target):
    with zipfile.ZipFile(archive) as bundle:
        for item in bundle.infolist():
            name = item.filename.rstrip("/")
            path = PurePosixPath(name)
            if (path.is_absolute() or path.as_posix() != name or ".." in path.parts
                    or "\\" in name or ":" in name
                    or (item.external_attr >> 16) & 0o170000 == 0o120000):
                raise ValueError("Unsafe source archive path")
            destination = target.joinpath(*path.parts)
            if item.is_dir():
                destination.mkdir(parents=True, exist_ok=True)
            else:
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(bundle.read(item))


class Builder:
    def __init__(self, config_path):
        self.config_path = Path(config_path).resolve()
        self.config = read_json(self.config_path)
        self.root = self.config_path.parent
        self.repo = Path(self.config["repository"]).resolve()
        if not (self.repo / "pubspec.yaml").is_file():
            raise ValueError("repository must be the Flutter project root")
        self.branch = self.config["branch"]
        if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_./-]*", self.branch) or ".." in self.branch:
            raise ValueError("Invalid branch")
        self.remote = self.config["remote"]
        if not self.remote or self.remote.startswith("-"):
            raise ValueError("Invalid remote")
        self.jobs = self.root / "jobs"
        self.jobs.mkdir(exist_ok=True)
        self.state_path = self.root / "main-state.json"
        self.state = read_json(self.state_path) if self.state_path.exists() else {}
        identity = {"repository": str(self.repo), "remote": self.remote, "branch": self.branch,
                    "python": self.config["python"],
                    "buildWindows": bool(self.config.get("buildWindows", False))}
        if self.state.get("configuration", identity) != identity:
            raise ValueError("Configuration changed: use a new installation directory to avoid reusing another deployment state")
        self.state["configuration"] = identity
        destination = self.config.get("transport")
        if self.state.get("destination") != destination:
            self.state.pop("delivery", None)
            self.state["destination"] = destination
        self.transport = None
        self.transport_error = "SSH transport is not configured"
        if destination:
            try:
                self.transport = SftpTransport(destination, self.root)
            except (ValueError, KeyError, OSError) as error:
                self.transport_error = str(error)
        self.env = dict(os.environ, GIT_TERMINAL_PROMPT="0", GCM_INTERACTIVE="Never",
                        GIT_SSH_COMMAND="ssh -oBatchMode=yes -oStrictHostKeyChecking=yes -oConnectTimeout=15")

    def save(self):
        write_json(self.state_path, self.state)

    def status(self, phase, message):
        self.state.update(phase=phase, message=message, updatedAt=datetime.now(timezone.utc).isoformat())
        self.save()
        LOG.info("%s: %s", phase, message)

    def command(self, arguments, cwd, log=None, timeout=3600):
        cwd = Path(cwd)
        if arguments[0] in {"flutter", "dart"}:
            LOG.info("cwd: %s; pubspec.yaml: %s", cwd, (cwd / "pubspec.yaml").is_file())
            if not (cwd / "pubspec.yaml").is_file():
                raise ValueError("Flutter/Dart command requires project root")
        LOG.info("command: %s", arguments[0:4])
        if os.name == "nt" and arguments[0] in {"flutter", "dart"}:
            if any(re.search(r'[&|<>^%!"\r\n]', argument) for argument in arguments):
                raise ValueError("Unsafe Flutter/Dart argument")
            arguments = ["cmd.exe", "/d", "/c", subprocess.list2cmdline(arguments)]
        if log:
            with Path(log).open("a", encoding="utf-8") as output:
                output.write("\nCOMMAND " + " ".join(arguments) + "\n")
                output.flush()
                subprocess.run(arguments, cwd=cwd, env=self.env, stdout=output, stderr=output, check=True, timeout=timeout)
            return ""
        result = subprocess.run(arguments, cwd=cwd, env=self.env, capture_output=True,
                                encoding="utf-8", errors="replace", timeout=timeout)
        if result.returncode:
            raise RuntimeError(result.stderr.strip()[-1500:] or "Command failed")
        return result.stdout.strip()

    def remote_head(self):
        output = self.command(["git", "ls-remote", "--exit-code", self.remote, "refs/heads/" + self.branch], self.repo, timeout=90)
        for line in output.splitlines():
            sha, ref = line.split()
            if ref == "refs/heads/" + self.branch and re.fullmatch(r"[0-9a-f]{40,64}", sha):
                return sha
        raise RuntimeError("Remote branch was not found")

    def snapshot(self, revision, job_root):
        mirror = self.root / "mirror.git"
        if not mirror.exists():
            self.command(["git", "init", "--bare", str(mirror)], self.repo)
        url = self.command(["git", "remote", "get-url", self.remote], self.repo)
        git = ["git", "--git-dir=" + str(mirror)]
        self.command(git + ["fetch", "--no-tags", "--", url, "refs/heads/" + self.branch], self.repo, timeout=600)
        fetched = self.command(git + ["rev-parse", "FETCH_HEAD"], self.repo)
        if fetched != revision:
            raise RuntimeError("Branch advanced during fetch; next poll will build its latest commit")
        names = self.command(git + ["ls-tree", "--name-only", revision], self.repo).splitlines()
        archive = job_root / "source.zip"
        self.command(git + ["archive", "--format=zip", "--output=" + str(archive), revision, "--",
                           *sorted(SOURCE_PATHS.intersection(names))], self.repo)
        source = job_root / ("source-" + uuid.uuid4().hex)
        source.mkdir()
        extract_source(archive, source)
        return source

    def build(self, revision):
        root = self.jobs / revision
        root.mkdir(exist_ok=True)
        path = root / "build.json"
        job = read_json(path) if path.exists() else {"completed": []}
        archive = root / "dist/host.zip"
        if job.get("built"):
            if file_hash(archive) != job["sha256"]:
                raise ValueError("Cached build is corrupt; inspect before retrying")
            return archive
        if "source" not in job:
            job["source"] = str(self.snapshot(revision, root))
            write_json(path, job)
        source = Path(job["source"])
        if not source.is_relative_to(root) or not (source / "pubspec.yaml").is_file():
            raise ValueError("Invalid saved source directory")
        match = re.search(r"^version:\s*(\d+\.\d+\.\d+\+\d+)\s*$", (source / "pubspec.yaml").read_text(encoding="utf-8"), re.M)
        if not match:
            raise ValueError("Expected numeric application version and build number")
        version = match[1]
        python = self.config["python"]
        runtime = json.loads(self.command([python, "-c", "import sys,struct,json; print(json.dumps([sys.version_info.major,sys.version_info.minor,struct.calcsize('P')*8]))"], source))
        if runtime[0] != 3 or runtime[1] < 10 or runtime[2] != 64:
            raise ValueError("Build Python must be 3.10+ x64 and match the host's Python minor version")
        build_python = str(source / ".build-python/Scripts/python.exe")
        steps = [
            ("venv", [python, "-m", "venv", str(source / ".build-python")]),
            ("wheels", [build_python, "-m", "pip", "download", "--only-binary=:all:", "-r", "requirements.txt", "-d", "wheelhouse"]),
            ("backend-dependencies", [build_python, "-m", "pip", "install", "--no-index", "--only-binary=:all:", "--find-links", "wheelhouse", "-r", "requirements.txt"]),
            ("test-dependencies", [build_python, "-m", "pip", "install", "httpx"]),
            ("backend-tests", [build_python, "-m", "unittest", "discover", "-s", "server/tests"]),
            ("update-tests", [build_python, "-m", "unittest", "discover", "-s", "tool/tests"]),
            ("pub", ["flutter", "pub", "get"]),
            ("generated", ["dart", "run", "build_runner", "build", "--delete-conflicting-outputs"]),
            ("flutter-tests", ["flutter", "test", "--no-pub"]),
            ("web", ["flutter", "build", "web", "--release", "--no-pub", "--pwa-strategy=none", "--dart-define=PDF_VIEWER_APP_VERSION=" + version]),
        ]
        if self.config.get("buildWindows", False):
            steps.append(("windows", ["flutter", "build", "windows", "--release", "--no-pub"]))
        for name, command in steps:
            if name in job["completed"]:
                continue
            self.status("building", revision + ": " + name)
            self.command(command, source, root / "build.log")
            job["completed"].append(name)
            write_json(path, job)
        package(source, archive.parent, revision, f"{runtime[0]}.{runtime[1]}")
        job.update(built=True, sha256=file_hash(archive), version=version)
        write_json(path, job)
        self.status("built", revision)
        return archive

    def refresh_host(self):
        if self.transport is None:
            self.state["hostError"] = self.transport_error
            self.save()
            return
        try:
            host = self.transport.read_status()
            self.state["host"] = host
            self.state["hostCheckedAt"] = datetime.now(timezone.utc).isoformat()
            self.state.pop("hostError", None)
            age = (datetime.now(timezone.utc) - datetime.fromisoformat(host["updatedAt"].replace("Z", "+00:00"))).total_seconds()
            if not -60 <= age <= 180:
                raise RuntimeError("Host heartbeat is stale; application completion is unconfirmed")
            delivery = self.state.get("delivery", {})
            if host.get("attemptedTag") == delivery.get("tag") and delivery:
                if host.get("state") == "failed":
                    self.status("apply_failed", "Host rejected or rolled back " + delivery["revision"])
                elif host.get("activeRevision") == delivery["revision"] and host.get("serverRunning") and host.get("state") == "succeeded":
                    if self.state.get("phase") != "applied":
                        self.status("applied", delivery["revision"])
        except Exception as error:
            self.state["hostError"] = str(error)
            LOG.warning("Host status unavailable: %s", error)
        self.save()

    def tick(self):
        self.refresh_host()
        revision = self.remote_head()
        delivery = self.state.get("delivery")
        if not delivery or delivery["revision"] != revision:
            sequence = max(time.time_ns(), self.state.get("sequence", 0) + 1)
            self.state.update(sequence=sequence, delivery={"revision": revision, "tag": f"host-{sequence}-1", "sent": False})
            self.status("detected", "Remote branch head: " + revision)
            delivery = self.state["delivery"]
        if delivery["sent"]:
            return
        archive = self.build(revision)
        if self.transport is None:
            self.status("awaiting_transport", self.transport_error)
            return
        # Never send an obsolete build if another push arrived during the build.
        if self.remote_head() != revision:
            self.status("superseded", "A newer push arrived; retained completed build for reuse")
            return
        self.status("transferring", revision)
        self.transport.publish(archive, revision, delivery["tag"])
        delivery["sent"] = True
        self.status("awaiting_apply", "Transferred; waiting for host confirmation: " + revision)

    def run(self, once=False):
        while True:
            try:
                self.tick()
                delay = max(10, self.config.get("pollSeconds", 60))
            except subprocess.TimeoutExpired as error:
                self.status("failed", str(error))
                # Exit the Windows job so timed-out build grandchildren cannot survive.
                raise
            except Exception as error:
                LOG.exception("Deployment failed; retrying with completed stages preserved")
                self.status("failed", str(error))
                if once:
                    raise
                delay = max(10, self.config.get("retrySeconds", 300))
            if once:
                return
            time.sleep(delay)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--status", action="store_true")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    config_path = Path(args.config).resolve()
    logging.basicConfig(filename=config_path.parent / "main-agent.log", encoding="utf-8", level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")
    if args.status:
        config = read_json(config_path)
        result = {"main": read_json(config_path.parent / "main-state.json") if (config_path.parent / "main-state.json").exists() else {}}
        try:
            if not config.get("transport"):
                raise ValueError("SSH transport is not configured; build-only mode")
            result["host"] = SftpTransport(config["transport"], config_path.parent).read_status()
        except Exception as error:
            result["hostError"] = str(error)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return
    with exclusive_lock(config_path.parent / "main-agent.lock"):
        builder = Builder(config_path)
        if args.check:
            print("Build configuration is valid; " + (builder.transport_error if builder.transport is None else "SSH authentication and remote paths still require verification"))
        else:
            contain_children()
            builder.run(args.once)


if __name__ == "__main__":
    main()
