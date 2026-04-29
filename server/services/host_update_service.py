from __future__ import annotations

import ctypes
import json
import os
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from server.core.errors import bad_request, server_error


CREATE_NEW_PROCESS_GROUP = 0x00000200
DETACHED_PROCESS = 0x00000008


def load_host_update_status(settings) -> dict[str, object]:
    path = _status_path(settings)
    if not path.is_file():
        return {"ok": True, "state": "idle"}

    try:
        payload = json.loads(path.read_text(encoding="utf-8-sig"))
    except Exception:
        return {"ok": True, "state": "unknown"}

    if isinstance(payload, dict):
        running_pid = _running_pid(payload)
        if running_pid is not None and not _is_process_running(running_pid):
            return {
                "ok": True,
                **payload,
                "state": "unknown",
                "message": "host update runner is not running",
            }
        return {"ok": True, **payload}
    return {"ok": True, "state": "unknown"}


def start_host_update(
    settings,
    project_root: Path,
    request_payload: dict[str, object] | None = None,
) -> dict[str, object]:
    runner_path = settings.host_update_runner_path
    if not runner_path.is_file():
        raise bad_request(f"host update runner was not found: {runner_path}")

    status = load_host_update_status(settings)
    running_pid = _running_pid(status)
    if running_pid is not None and _is_process_running(running_pid):
        return {"ok": True, "state": "running", "pid": running_pid}

    settings.data_dir.mkdir(parents=True, exist_ok=True)
    _write_status(
        settings,
        {
            "state": "queued",
            "startedAt": _now_iso(),
            "message": "host update was queued",
            "request": _clean_request_payload(request_payload),
        },
    )

    arguments = [
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(runner_path),
        "-ProjectRoot",
        str(project_root),
        "-Remote",
        settings.host_update_remote,
        "-ServerPort",
        str(settings.port),
    ]
    if settings.host_update_branch:
        arguments.extend(["-Branch", settings.host_update_branch])
    if settings.host_update_build_android_apk:
        arguments.append("-BuildAndroidApk")

    try:
        process = subprocess.Popen(
            arguments,
            cwd=str(project_root),
            creationflags=CREATE_NEW_PROCESS_GROUP | DETACHED_PROCESS if os.name == "nt" else 0,
            close_fds=True,
        )
    except Exception as error:
        _write_status(
            settings,
            {
                "state": "failed",
                "finishedAt": _now_iso(),
                "message": f"failed to start host update runner: {error}",
            },
        )
        raise server_error(f"Failed to start host update runner: {error}") from error

    _write_status(
        settings,
        {
            "state": "running",
            "pid": process.pid,
            "startedAt": _now_iso(),
            "message": "host update runner started",
            "request": _clean_request_payload(request_payload),
        },
    )
    return {"ok": True, "state": "running", "pid": process.pid}


def _clean_request_payload(payload: dict[str, object] | None) -> dict[str, str]:
    if not payload:
        return {}
    allowed = ("clientVersion", "hostVersion", "latestVersion")
    return {
        key: str(payload.get(key) or "").strip()[:80]
        for key in allowed
        if str(payload.get(key) or "").strip()
    }


def _status_path(settings) -> Path:
    return settings.data_dir / "host_update_status.json"


def _write_status(settings, payload: dict[str, object]) -> None:
    path = _status_path(settings)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = path.with_suffix(".tmp")
    temp_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    temp_path.replace(path)


def _running_pid(status: dict[str, object]) -> int | None:
    if status.get("state") != "running":
        return None
    try:
        pid = int(status.get("pid") or 0)
    except (TypeError, ValueError):
        return None
    return pid if pid > 0 else None


def _is_process_running(pid: int) -> bool:
    if os.name == "nt":
        kernel32 = ctypes.windll.kernel32
        handle = kernel32.OpenProcess(0x1000, False, pid)
        if not handle:
            return False
        try:
            exit_code = ctypes.c_ulong()
            if not kernel32.GetExitCodeProcess(handle, ctypes.byref(exit_code)):
                return False
            return exit_code.value == 259
        finally:
            kernel32.CloseHandle(handle)

    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()
