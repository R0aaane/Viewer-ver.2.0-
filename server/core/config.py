from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


def _parse_bool(raw: str | None, default: bool) -> bool:
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _parse_csv(raw: str | None) -> list[str]:
    if raw is None:
        return []
    values = [entry.strip() for entry in raw.replace("\n", ";").split(";")]
    return [entry for entry in values if entry]


@dataclass(frozen=True)
class Settings:
    service_name: str
    version: str
    host: str
    port: int
    data_dir: Path
    sqlite_path: Path
    thumbs_dir: Path
    auth_token: str | None
    cors_allow_origins: list[str]
    media_roots: list[str]
    log_level: str
    startup_rescan: bool
    stream_chunk_size: int
    update_version: str | None
    update_url: str | None
    host_update_runner_path: Path
    host_update_remote: str
    host_update_branch: str | None
    host_update_build_android_apk: bool


def load_settings() -> Settings:
    project_root = Path(__file__).resolve().parents[2]
    data_dir = Path(os.getenv("MEDIA_SERVER_DATA_DIR", project_root / "data")).resolve()
    sqlite_path = Path(
        os.getenv("MEDIA_SERVER_DB_PATH", data_dir / "metadata.db"),
    ).resolve()
    thumbs_dir = Path(
        os.getenv("MEDIA_SERVER_THUMBS_DIR", data_dir / "thumbs"),
    ).resolve()

    return Settings(
        service_name=os.getenv("MEDIA_SERVER_NAME", "metadata-media-server"),
        version=os.getenv("MEDIA_SERVER_VERSION", "0.1.0"),
        host=os.getenv("MEDIA_SERVER_HOST", "127.0.0.1"),
        port=int(os.getenv("MEDIA_SERVER_PORT", "8000")),
        data_dir=data_dir,
        sqlite_path=sqlite_path,
        thumbs_dir=thumbs_dir,
        auth_token=(os.getenv("MEDIA_SERVER_AUTH_TOKEN") or "").strip() or None,
        cors_allow_origins=_parse_csv(
            os.getenv("MEDIA_SERVER_CORS_ORIGINS", "http://localhost;http://127.0.0.1"),
        ),
        media_roots=_parse_csv(os.getenv("MEDIA_SERVER_MEDIA_ROOTS")),
        log_level=os.getenv("MEDIA_SERVER_LOG_LEVEL", "INFO"),
        startup_rescan=_parse_bool(os.getenv("MEDIA_SERVER_STARTUP_RESCAN"), True),
        stream_chunk_size=int(os.getenv("MEDIA_SERVER_STREAM_CHUNK_SIZE", str(1024 * 1024))),
        update_version=(os.getenv("MEDIA_SERVER_UPDATE_VERSION") or "").strip() or None,
        update_url=(os.getenv("MEDIA_SERVER_UPDATE_URL") or "").strip() or None,
        host_update_runner_path=Path(
            os.getenv(
                "MEDIA_SERVER_HOST_UPDATE_RUNNER",
                project_root / "tool" / "host_update_runner.ps1",
            ),
        ).resolve(),
        host_update_remote=os.getenv("MEDIA_SERVER_HOST_UPDATE_REMOTE", "origin"),
        host_update_branch=(os.getenv("MEDIA_SERVER_HOST_UPDATE_BRANCH") or "").strip() or None,
        host_update_build_android_apk=_parse_bool(
            os.getenv("MEDIA_SERVER_HOST_UPDATE_BUILD_ANDROID_APK"),
            True,
        ),
    )
