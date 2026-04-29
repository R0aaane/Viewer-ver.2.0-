from __future__ import annotations

import logging
import mimetypes
import os
import stat
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


def _is_hidden_entry(path: str) -> bool:
    name = os.path.basename(os.path.normpath(path))
    if name.startswith('.') and name not in {'.', '..'}:
        return True

    hidden_flag = int(getattr(stat, 'FILE_ATTRIBUTE_HIDDEN', 0) or 0)
    if hidden_flag == 0:
        return False

    try:
        file_attributes = int(getattr(os.stat(path), 'st_file_attributes', 0) or 0)
    except OSError:
        return False
    return (file_attributes & hidden_flag) != 0


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
        indexed_media_ids: list[str] = []
        gif_member_paths: set[str] = set()
        gif_dirs = {
            os.path.dirname(os.path.normpath(raw_path))
            for raw_path in paths
            if Path(raw_path).suffix.lower() == ".gif"
            and os.path.isfile(os.path.normpath(raw_path))
        }
        for gif_dir in sorted(gif_dirs):
            try:
                file_names = os.listdir(gif_dir)
            except OSError:
                continue
            record = self._build_record_for_gif_collection(gif_dir, file_names)
            if record is None:
                continue
            stable_record = self._preserve_existing_media_identity(record)
            self._db.upsert_media_record(stable_record)
            indexed_media_ids.append(str(stable_record["media_id"]))
            indexed += 1
            gif_member_paths.update(
                _normalize_path(os.path.join(gif_dir, file_name))
                for file_name in file_names
                if Path(file_name).suffix.lower() == ".gif"
            )

        for raw_path in paths:
            if _normalize_path(raw_path) in gif_member_paths:
                continue
            record = self._build_record_for_path(raw_path)
            if record is None:
                continue
            stable_record = self._preserve_existing_media_identity(record)
            self._db.upsert_media_record(stable_record)
            if str(stable_record.get("kind") or "") == "pdf":
                indexed_media_ids.append(str(stable_record["media_id"]))
            indexed += 1
        if indexed_media_ids:
            self._db.ensure_media_stats(
                indexed_media_ids,
                added_at=datetime.now(tz=timezone.utc).isoformat(),
            )
        if gif_member_paths:
            self._db.mark_deleted_by_paths(list(gif_member_paths), is_deleted=True)
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
        indexed_media_ids: list[str] = []
        try:
            for base, dirs, files in os.walk(target, onerror=lambda error: logger.warning('scan walk warning: %s (%s)', target, error)):
                dirs[:] = [
                    directory_name
                    for directory_name in dirs
                    if not _is_hidden_entry(os.path.join(base, directory_name))
                ]
                gif_collection_record = (
                    self._build_record_for_gif_collection(base, files)
                    if _normalize_path(base) != normalized_root
                    else None
                )
                gif_collection_names: set[str] = set()
                if gif_collection_record is not None:
                    stable_record = self._preserve_existing_media_identity(gif_collection_record)
                    self._db.upsert_media_record(stable_record)
                    indexed_media_ids.append(str(stable_record['media_id']))
                    found_paths.add(str(stable_record['normalized_full_path']))
                    scanned += 1
                    gif_collection_names = {
                        file_name
                        for file_name in files
                        if Path(file_name).suffix.lower() == ".gif"
                    }
                for file_name in files:
                    if file_name in gif_collection_names:
                        continue
                    if _is_hidden_entry(os.path.join(base, file_name)):
                        continue
                    full_path = os.path.normpath(os.path.join(base, file_name))
                    record = self._build_record_for_path(full_path)
                    if record is None:
                        continue
                    stable_record = self._preserve_existing_media_identity(record)
                    self._db.upsert_media_record(stable_record)
                    if str(stable_record.get('kind') or '') == 'pdf':
                        indexed_media_ids.append(str(stable_record['media_id']))
                    found_paths.add(str(stable_record['normalized_full_path']))
                    scanned += 1

            if indexed_media_ids:
                self._db.ensure_media_stats(
                    indexed_media_ids,
                    added_at=datetime.now(tz=timezone.utc).isoformat(),
                )

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
        if _is_hidden_entry(full_path):
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

    def _build_record_for_gif_collection(
        self,
        directory_path: str,
        file_names: list[str],
    ) -> dict[str, object] | None:
        gif_names = sorted(
            file_name
            for file_name in file_names
            if Path(file_name).suffix.lower() == ".gif"
            and not _is_hidden_entry(os.path.join(directory_path, file_name))
        )
        if not gif_names:
            return None

        full_path = os.path.normpath(directory_path)
        try:
            size_bytes = 0
            modified_epoch_ms = 0
            for file_name in gif_names:
                stat = os.stat(os.path.join(full_path, file_name))
                size_bytes += int(stat.st_size)
                modified_epoch_ms = max(modified_epoch_ms, int(stat.st_mtime * 1000))
            modified_at = datetime.fromtimestamp(
                modified_epoch_ms / 1000,
                tz=timezone.utc,
            ).isoformat()
            folder_of_item = os.path.dirname(full_path)
            display_name = os.path.basename(full_path)
            media_id = build_media_id(
                kind="pdf",
                full_path=full_path,
                folder_raw=folder_of_item,
                display_name=display_name,
                size_bytes=size_bytes,
                modified_epoch_ms=modified_epoch_ms,
            )
        except OSError as error:
            logger.warning('scan skip unreadable gif collection: %s (%s)', full_path, error)
            return None

        return {
            'media_id': media_id,
            'folder_raw': folder_of_item,
            'relative_hint': display_name,
            'display_name': display_name,
            'full_path': full_path,
            'normalized_full_path': _normalize_path(full_path),
            'kind': "pdf",
            'mime_type': "application/x.gif-collection",
            'size_bytes': size_bytes,
            'modified_at': modified_at,
            'modified_epoch_ms': modified_epoch_ms,
            'etag': _etag_for_file(full_path, size_bytes, modified_epoch_ms),
            'is_deleted': 0,
        }
