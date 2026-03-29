import logging
import mimetypes
import os
from datetime import datetime, timezone
from pathlib import Path

from server.core.errors import bad_request
from server.core.media_formats import SUPPORTED_MEDIA_EXTENSIONS, media_kind_for_extension
from server.repositories.sqlite_store import SqliteStore
from server.services.metadata_store import build_media_id


logger = logging.getLogger(__name__)


def _normalize_path(raw: str) -> str:
    normalized = os.path.normpath(raw).replace("/", "\\")
    return normalized.casefold()


def _media_kind(path: str) -> str | None:
    return media_kind_for_extension(Path(path).suffix.lower())


def _etag_for_file(path: str, size_bytes: int, modified_epoch_ms: int) -> str:
    source = f"{_normalize_path(path)}|{size_bytes}|{modified_epoch_ms}"
    value = 0x811C9DC5
    prime = 0x01000193
    for unit in source.encode("utf-8"):
        value ^= unit
        value = (value * prime) & 0xFFFFFFFF
    return f"{value:08x}"


class MediaIndexService:
    def __init__(self, sqlite_store: SqliteStore) -> None:
        self._db = sqlite_store

    def rescan_configured_roots(self, roots: list[str]) -> list[dict[str, int | str]]:
        results: list[dict[str, int | str]] = []
        for root in roots:
            scanned = self.scan_folder(root)
            results.append({"folderRaw": root, "count": scanned})
        return results

    def scan_folder(self, folder_raw: str) -> int:
        target = os.path.normpath(folder_raw)
        if not os.path.isdir(target):
            raise bad_request(f"対象フォルダが存在しません: {folder_raw}")

        normalized_root = _normalize_path(target)
        logger.info("scan start: %s", target)

        found_paths: set[str] = set()
        scanned = 0
        for base, _, files in os.walk(target):
            for file_name in files:
                ext = Path(file_name).suffix.lower()
                if ext not in SUPPORTED_MEDIA_EXTENSIONS:
                    continue

                full_path = os.path.normpath(os.path.join(base, file_name))
                kind = _media_kind(full_path)
                if kind is None:
                    continue

                stat = os.stat(full_path)
                size_bytes = int(stat.st_size)
                modified_epoch_ms = int(stat.st_mtime * 1000)
                modified_at = datetime.fromtimestamp(
                    stat.st_mtime,
                    tz=timezone.utc,
                ).isoformat()
                mime_type, _ = mimetypes.guess_type(full_path)
                folder_of_item = os.path.dirname(full_path)
                media_id = build_media_id(
                    kind=kind,
                    full_path=full_path,
                    folder_raw=folder_of_item,
                    display_name=file_name,
                    size_bytes=size_bytes,
                    modified_epoch_ms=modified_epoch_ms,
                )

                record = {
                    "media_id": media_id,
                    "folder_raw": folder_of_item,
                    "relative_hint": file_name,
                    "display_name": file_name,
                    "full_path": full_path,
                    "normalized_full_path": _normalize_path(full_path),
                    "kind": kind,
                    "mime_type": mime_type,
                    "size_bytes": size_bytes,
                    "modified_at": modified_at,
                    "modified_epoch_ms": modified_epoch_ms,
                    "etag": _etag_for_file(full_path, size_bytes, modified_epoch_ms),
                    "is_deleted": 0,
                }
                self._db.upsert_media_record(record)
                found_paths.add(record["normalized_full_path"])
                scanned += 1

        existing = self._db.list_media_records(folder_prefix=normalized_root, include_deleted=True)
        stale_ids = [
            row["media_id"]
            for row in existing
            if row["normalized_full_path"] not in found_paths
        ]
        self._db.mark_deleted_by_ids(stale_ids, is_deleted=True)
        self._db.upsert_indexed_folder(
            folder_raw=target,
            normalized_folder_raw=normalized_root,
            display_name=Path(target).name or target,
            last_scanned_at=datetime.now(tz=timezone.utc).isoformat(),
        )
        logger.info("scan finished: %s (%s files)", target, scanned)
        return scanned
