from __future__ import annotations

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

mimetypes.add_type('image/avif', '.avif')


def _normalize_path(raw: str) -> str:
    normalized = os.path.normpath(raw).replace('/', '\\')
    return normalized.casefold()


def _media_kind(path: str) -> str | None:
    return media_kind_for_extension(Path(path).suffix.lower())


def _etag_for_file(path: str, size_bytes: int, modified_epoch_ms: int) -> str:
    source = f"{_normalize_path(path)}|{size_bytes}|{modified_epoch_ms}"
    value = 0x811C9DC5
    prime = 0x01000193
    for unit in source.encode('utf-8'):
        value ^= unit
        value = (value * prime) & 0xFFFFFFFF
    return f"{value:08x}"


class MediaIndexService:
    def __init__(self, sqlite_store: SqliteStore) -> None:
        self._db = sqlite_store

    def index_files(self, paths: list[str]) -> int:
        indexed = 0
        for raw_path in paths:
            record = self._build_record_for_path(raw_path)
            if record is None:
                continue
            stable_record = self._preserve_existing_media_identity(record)
            self._db.upsert_media_record(stable_record)
            indexed += 1
        return indexed

    def rescan_configured_roots(self, roots: list[str]) -> list[dict[str, int | str]]:
        results: list[dict[str, int | str]] = []
        seen_roots: set[str] = set()
        for root in roots:
            normalized_root = _normalize_path(root)
            if normalized_root in seen_roots:
                logger.info('scan skip duplicated root: %s', root)
                continue
            seen_roots.add(normalized_root)
            scanned = self.scan_folder(root)
            results.append({'folderRaw': root, 'count': scanned})
        return results

    def scan_folder(self, folder_raw: str) -> int:
        target = os.path.normpath(folder_raw)
        if not os.path.isdir(target):
            raise bad_request(f'対象フォルダが存在しません: {folder_raw}')

        normalized_root = _normalize_path(target)
        logger.info('scan start: %s', target)

        found_paths: set[str] = set()
        scanned = 0
        try:
            for base, _, files in os.walk(target, onerror=lambda error: logger.warning('scan walk warning: %s (%s)', target, error)):
                for file_name in files:
                    full_path = os.path.normpath(os.path.join(base, file_name))
                    record = self._build_record_for_path(full_path)
                    if record is None:
                        continue
                    stable_record = self._preserve_existing_media_identity(record)
                    self._db.upsert_media_record(stable_record)
                    found_paths.add(str(stable_record['normalized_full_path']))
                    scanned += 1

            existing = self._db.list_media_records(
                folder_prefix=normalized_root,
                include_deleted=True,
            )
            stale_ids = [
                row['media_id']
                for row in existing
                if row['normalized_full_path'] not in found_paths
            ]
            self._db.mark_deleted_by_ids(stale_ids, is_deleted=True)
            self._db.upsert_indexed_folder(
                folder_raw=target,
                normalized_folder_raw=normalized_root,
                display_name=Path(target).name or target,
                last_scanned_at=datetime.now(tz=timezone.utc).isoformat(),
            )
        except Exception:
            logger.exception('scan failed: %s', target)
            raise

        logger.info('scan finished: %s (%s files)', target, scanned)
        return scanned

    def _preserve_existing_media_identity(
        self,
        record: dict[str, object],
    ) -> dict[str, object]:
        normalized_full_path = str(record['normalized_full_path'])
        existing = self._db.get_media_record_by_normalized_path(normalized_full_path)
        if existing is None:
            return record

        existing_media_id = str(existing['media_id'])
        incoming_media_id = str(record['media_id'])
        if existing_media_id == incoming_media_id:
            return record

        logger.info(
            'scan reuse media_id for path=%s existing=%s incoming=%s',
            record['full_path'],
            existing_media_id,
            incoming_media_id,
        )
        updated = dict(record)
        updated['media_id'] = existing_media_id
        return updated

    def _build_record_for_path(self, raw_path: str) -> dict[str, object] | None:
        full_path = os.path.normpath(raw_path)
        if not os.path.isfile(full_path):
            return None

        ext = Path(full_path).suffix.lower()
        if ext not in SUPPORTED_MEDIA_EXTENSIONS:
            return None

        kind = _media_kind(full_path)
        if kind is None:
            return None

        try:
            stat = os.stat(full_path)
            size_bytes = int(stat.st_size)
            modified_epoch_ms = int(stat.st_mtime * 1000)
            modified_at = datetime.fromtimestamp(
                stat.st_mtime,
                tz=timezone.utc,
            ).isoformat()
            mime_type, _ = mimetypes.guess_type(full_path)
            folder_of_item = os.path.dirname(full_path)
            file_name = os.path.basename(full_path)
            media_id = build_media_id(
                kind=kind,
                full_path=full_path,
                folder_raw=folder_of_item,
                display_name=file_name,
                size_bytes=size_bytes,
                modified_epoch_ms=modified_epoch_ms,
            )
        except OSError as error:
            logger.warning('scan skip unreadable file: %s (%s)', full_path, error)
            return None

        return {
            'media_id': media_id,
            'folder_raw': folder_of_item,
            'relative_hint': file_name,
            'display_name': file_name,
            'full_path': full_path,
            'normalized_full_path': _normalize_path(full_path),
            'kind': kind,
            'mime_type': mime_type,
            'size_bytes': size_bytes,
            'modified_at': modified_at,
            'modified_epoch_ms': modified_epoch_ms,
            'etag': _etag_for_file(full_path, size_bytes, modified_epoch_ms),
            'is_deleted': 0,
        }