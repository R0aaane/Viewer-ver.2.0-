from __future__ import annotations

import json
import re
import secrets
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from fastapi import UploadFile

from server.core.errors import bad_request


_ALLOWED_EXTENSIONS = {
    ".apk",
    ".aab",
    ".zip",
    ".msi",
    ".msix",
    ".exe",
    ".dmg",
    ".pkg",
}


@dataclass(frozen=True)
class AppUpdateInfo:
    version: str
    file_name: str
    original_file_name: str
    size_bytes: int
    uploaded_at: str


def update_download_path(info: AppUpdateInfo) -> str:
    return f"/app-updates/{info.file_name}"


def load_app_update_info(settings) -> AppUpdateInfo | None:
    manifest = _manifest_path(settings)
    if not manifest.is_file():
        return None

    try:
        raw = json.loads(manifest.read_text(encoding="utf-8"))
        info = AppUpdateInfo(
            version=str(raw.get("version") or "").strip(),
            file_name=str(raw.get("fileName") or "").strip(),
            original_file_name=str(raw.get("originalFileName") or "").strip(),
            size_bytes=int(raw.get("sizeBytes") or 0),
            uploaded_at=str(raw.get("uploadedAt") or "").strip(),
        )
    except Exception:
        return None

    if not info.version or not info.file_name:
        return None
    if not app_update_file_path(settings, info).is_file():
        return None
    return info


def app_update_file_path(settings, info: AppUpdateInfo) -> Path:
    return (_updates_dir(settings) / info.file_name).resolve()


async def save_app_update_upload(
    settings,
    *,
    version: str,
    upload: UploadFile,
) -> AppUpdateInfo:
    normalized_version = version.strip()
    if not normalized_version:
        raise bad_request("version is required")

    original_file_name = _sanitize_file_name(upload.filename or "")
    suffix = Path(original_file_name).suffix.lower()
    if suffix not in _ALLOWED_EXTENSIONS:
        raise bad_request("unsupported update file type")

    updates_dir = _updates_dir(settings)
    updates_dir.mkdir(parents=True, exist_ok=True)

    safe_version = re.sub(r"[^0-9A-Za-z._+-]+", "_", normalized_version)
    file_name = f"pdf_viewer_{safe_version}_{secrets.token_hex(8)}{suffix}"
    target = (updates_dir / file_name).resolve()
    if target.parent != updates_dir.resolve():
        raise bad_request("invalid update file name")

    size_bytes = 0
    with tempfile.NamedTemporaryFile(
        dir=updates_dir,
        prefix=".upload-",
        suffix=".tmp",
        delete=False,
    ) as handle:
        temp_path = Path(handle.name)
        while True:
            chunk = await upload.read(1024 * 1024)
            if not chunk:
                break
            size_bytes += len(chunk)
            handle.write(chunk)

    if size_bytes <= 0:
        temp_path.unlink(missing_ok=True)
        raise bad_request("update file is empty")

    temp_path.replace(target)

    previous = load_app_update_info(settings)
    info = AppUpdateInfo(
        version=normalized_version,
        file_name=file_name,
        original_file_name=original_file_name,
        size_bytes=size_bytes,
        uploaded_at=datetime.now(timezone.utc).isoformat(),
    )
    _write_manifest(settings, info)

    if previous is not None and previous.file_name != info.file_name:
        app_update_file_path(settings, previous).unlink(missing_ok=True)

    return info


def _write_manifest(settings, info: AppUpdateInfo) -> None:
    manifest = _manifest_path(settings)
    manifest.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "version": info.version,
        "fileName": info.file_name,
        "originalFileName": info.original_file_name,
        "sizeBytes": info.size_bytes,
        "uploadedAt": info.uploaded_at,
    }
    temp_path = manifest.with_suffix(".tmp")
    temp_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    temp_path.replace(manifest)


def _updates_dir(settings) -> Path:
    return (settings.data_dir / "app_updates").resolve()


def _manifest_path(settings) -> Path:
    return _updates_dir(settings) / "latest.json"


def _sanitize_file_name(value: str) -> str:
    name = Path(value.strip()).name
    if not name:
        name = "app-update.zip"
    return re.sub(r"[^0-9A-Za-z._ +()-]+", "_", name)
