"""OpenSSH SFTP transport. No remote commands, passwords, or disabled host checks."""
import json
from pathlib import Path
import re
import subprocess
import tempfile
import uuid

try:
    from .host_release_agent import read_json, write_json, file_hash, release_order
except ImportError:
    from host_release_agent import read_json, write_json, file_hash, release_order


def quoted_path(value):
    value = str(value).replace("\\", "/")
    if any(c in value for c in '\r\n"*?[]') or not value:
        raise ValueError("SFTP paths must not contain quotes, newlines or wildcards")
    return '"' + value + '"'


class SftpTransport:
    def __init__(self, config, workdir):
        self.config = config
        self.workdir = Path(workdir)
        target = config["target"]
        if not re.fullmatch(r"[\w.][\w.@-]*", target, flags=re.ASCII):
            raise ValueError("Use an SSH hostname/IPv4 address or user@hostname")
        for key in ("inbox", "status"):
            if not config[key].startswith("/") or ".." in config[key].split("/"):
                raise ValueError("Remote paths must be absolute SFTP paths")
            quoted_path(config[key])
        for key in ("identityFile", "knownHostsFile"):
            if not Path(config[key]).is_absolute() or not Path(config[key]).is_file():
                raise ValueError(f"{key} must name an existing absolute path")
            quoted_path(config[key])

    def batch(self, commands):
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", suffix=".sftp", dir=self.workdir, delete=False) as handle:
            handle.write("\n".join(commands) + "\n")
            path = Path(handle.name)
        try:
            result = subprocess.run([
                "sftp", "-b", str(path), "-P", str(int(self.config.get("port", 22))),
                "-i", self.config["identityFile"], "-oBatchMode=yes", "-oIdentitiesOnly=yes",
                "-oStrictHostKeyChecking=yes", "-oConnectTimeout=15",
                "-oServerAliveInterval=15", "-oServerAliveCountMax=3",
                "-oUserKnownHostsFile=" + quoted_path(self.config["knownHostsFile"]), self.config["target"],
            ], capture_output=True, encoding="utf-8", errors="replace", timeout=1800)
            if result.returncode:
                raise RuntimeError("SFTP failed: " + result.stderr.strip()[-1500:])
        finally:
            path.unlink(missing_ok=True)

    def read_remote_json(self, remote):
        path = self.workdir / (uuid.uuid4().hex + ".json")
        try:
            self.batch([f"get {quoted_path(remote)} {quoted_path(path)}"])
            return read_json(path)
        finally:
            path.unlink(missing_ok=True)

    def read_status(self):
        return self.read_remote_json(self.config["status"])

    def publish(self, archive, revision, tag):
        release_order(tag)
        checksum = file_hash(archive)
        inbox = self.config["inbox"].rstrip("/")
        ready = inbox + "/" + tag + ".json"
        try:
            existing = self.read_remote_json(ready)
        except RuntimeError:
            existing = None  # Missing file or connection failure; upload must still succeed.
        if existing is not None:
            if existing.get("revision") != revision or existing.get("sha256") != checksum:
                raise ValueError("Published delivery already exists with different contents")
            return
        name = tag + "-" + uuid.uuid4().hex + ".zip"
        descriptor = self.workdir / (uuid.uuid4().hex + ".json")
        write_json(descriptor, {"tag_name": tag, "revision": revision, "sha256": checksum, "archive": name})
        remote_archive = inbox + "/" + name
        remote_ready_temp = ready + "." + uuid.uuid4().hex + ".part"
        try:
            # A unique final archive prevents retries from replacing an archive in use.
            # Only the final descriptor makes this delivery visible to the host agent.
            self.batch([
                f"put {quoted_path(archive)} {quoted_path(remote_archive + '.part')}",
                f"rename {quoted_path(remote_archive + '.part')} {quoted_path(remote_archive)}",
                f"put {quoted_path(descriptor)} {quoted_path(remote_ready_temp)}",
                f"rename {quoted_path(remote_ready_temp)} {quoted_path(ready)}",
            ])
        finally:
            descriptor.unlink(missing_ok=True)
