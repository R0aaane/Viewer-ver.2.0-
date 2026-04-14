from __future__ import annotations

import json
import logging
import os
import re
import shutil
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from server.core.errors import bad_request, not_found
from server.repositories.sqlite_store import SqliteStore
from server.services.tag_alias_service import TagAliasService


logger = logging.getLogger(__name__)


def _normalize_name(name: str) -> str:
    return name.strip().casefold()


def _normalize_path(raw: str) -> str:
    normalized = os.path.normpath(raw).replace("/", "\\")
    return normalized.casefold()


def _log_value(value: Any) -> str:
    if value is None:
        return "null"
    return json.dumps(str(value), ensure_ascii=False)


def _log_request_id(request_id: str | None) -> str:
    trimmed = str(request_id or "").strip()
    return trimmed or "-"


def _parse_datetime(raw: str | None) -> datetime | None:
    if not raw:
        return None
    try:
        return datetime.fromisoformat(raw)
    except ValueError:
        return None


def _parse_epoch(raw: Any) -> int | None:
    if raw is None:
        return None
    try:
        return int(raw)
    except (TypeError, ValueError):
        return None


def _utcnow_iso() -> str:
    return datetime.now(tz=timezone.utc).isoformat()


def _fnv1a64_hex(source: str) -> str:
    value = 0xCBF29CE484222325
    prime = 0x100000001B3
    for unit in source.encode("utf-8"):
        value ^= unit
        value = (value * prime) & 0xFFFFFFFFFFFFFFFF
    return f"{value:016x}"


def build_media_id(
    *,
    kind: str,
    full_path: str,
    folder_raw: str,
    display_name: str,
    size_bytes: int | None,
    modified_epoch_ms: int | None,
) -> str:
    normalized_path = _normalize_path(full_path)
    normalized_folder = _normalize_path(folder_raw)
    source = "|".join(
        [
            "v1",
            kind,
            normalized_path,
            normalized_folder,
            display_name,
            str(size_bytes if size_bytes is not None else -1),
            str(modified_epoch_ms if modified_epoch_ms is not None else -1),
        ]
    )
    return f"mid_{_fnv1a64_hex(source)}"


def _sanitize_dir_name(input_value: str) -> str:
    value = input_value.strip()
    if not value:
        return "_"
    value = re.sub(r'[\\/:*?"<>|]', "_", value)
    value = re.sub(r'[\x00-\x1F]', "_", value)
    value = re.sub(r'[\. ]+$', "", value)
    return value or "_"


def _same_file(source_path: str, target_path: str) -> bool:
    if _normalize_path(source_path) == _normalize_path(target_path):
        return True

    try:
        return os.path.samefile(source_path, target_path)
    except OSError:
        pass

    if not os.path.isfile(source_path) or not os.path.isfile(target_path):
        return False

    try:
        source_stat = os.stat(source_path)
        target_stat = os.stat(target_path)
    except OSError:
        return False

    return (
        int(source_stat.st_size) == int(target_stat.st_size)
        and int(source_stat.st_mtime * 1000) == int(target_stat.st_mtime * 1000)
    )


def _pick_first_tag_name(tags: list[dict[str, Any]], category: str) -> str | None:
    for tag in tags:
        if tag.get("category") != category:
            continue
        name = str(tag.get("name") or "").strip()
        if name:
            return name
    return None


def _tag_names_for_category(tags: list[dict[str, Any]], category: str) -> list[str]:
    names: list[str] = []
    seen: set[str] = set()
    for tag in tags:
        if tag.get("category") != category:
            continue
        name = str(tag.get("name") or "").strip()
        normalized_name = _normalize_name(name)
        if not normalized_name or normalized_name in seen:
            continue
        seen.add(normalized_name)
        names.append(name)
    return names


def _remove_empty_ancestor_dirs(*, start_dir: str, stop_at: str) -> None:
    normalized_stop = os.path.normcase(os.path.normpath(stop_at))
    current = os.path.normcase(os.path.normpath(start_dir))
    while current != normalized_stop and current.startswith(normalized_stop + "\\"):
        if not _remove_empty_dir_if_possible(current):
            break
        parent = os.path.normcase(os.path.normpath(os.path.dirname(current)))
        if parent == current:
            break
        current = parent


def _remove_empty_dir_if_possible(dir_path: str) -> bool:
    try:
        if not os.path.isdir(dir_path):
            return False
        if os.listdir(dir_path):
            return False
        os.rmdir(dir_path)
        return True
    except OSError:
        return False


def _remove_empty_legacy_author_dirs(library_root: str) -> None:
    legacy_root = os.path.join(library_root, "\u4f5c\u8005\u5225")
    if not os.path.isdir(legacy_root):
        return

    for base, _, _ in os.walk(legacy_root, topdown=False):
        _remove_empty_dir_if_possible(base)


@dataclass(frozen=True)
class SearchQuery:
    q: str | None = None
    artist: str | None = None
    series: str | None = None
    character: str | None = None
    media_type: str | None = None
    name: str | None = None
    partial: bool = False
    folder_raw: str | None = None
    limit: int = 50
    offset: int = 0


class MetadataStore:
    def __init__(
        self,
        sqlite_store: SqliteStore,
        *,
        tag_alias_service: TagAliasService | None = None,
    ) -> None:
        self._db = sqlite_store
        self._tag_aliases = tag_alias_service or TagAliasService()

    def list_indexed_folders(self) -> list[dict[str, Any]]:
        rows = self._db.list_indexed_folders()
        return [
            {
                "folderRaw": row["folder_raw"],
                "displayName": row["display_name"],
                "lastScannedAt": _parse_datetime(row["last_scanned_at"]),
            }
            for row in rows
        ]

    def get_media(self, media_id: str) -> dict[str, Any]:
        row = self._db.get_media_record(media_id)
        if row is None:
            raise not_found("Media was not found")
        return self._row_to_media_dict(row)

    def seed_missing_media_stats(self) -> int:
        media_ids = [
            str(row["media_id"])
            for row in self._db.list_media_records(include_deleted=False)
            if str(row.get("kind") or "") == "pdf"
        ]
        unique_ids = list(dict.fromkeys(media_ids))
        if not unique_ids:
            return 0
        existing = self._db.list_media_stats(unique_ids)
        self._db.ensure_media_stats(unique_ids, added_at=_utcnow_iso())
        return max(0, len(unique_ids) - len(existing))

    def get_media_stats(self, media_id: str) -> dict[str, Any]:
        resolved_media_id = self.resolve_media_id(media_id)
        stats_map = self._ensure_stats_for_media_ids([resolved_media_id])
        stats = stats_map.get(resolved_media_id)
        if stats is None:
            raise not_found("Media stats were not found")
        return stats

    def record_media_view(self, media_id: str) -> dict[str, Any]:
        media = self.get_media(media_id)
        if media["kind"] != "pdf":
            raise bad_request("Viewer stats are only available for PDF media")
        resolved_media_id = str(media["mediaId"])
        now = _utcnow_iso()
        row = self._db.increment_media_view(
            resolved_media_id,
            viewed_at=now,
            added_at=now,
        )
        return self._stats_row_to_dict(row) or {
            "addedAt": _parse_datetime(now),
            "lastViewedAt": _parse_datetime(now),
            "viewCount": 1,
        }

    def list_recent_media_activity(self, *, limit: int = 24) -> list[dict[str, Any]]:
        rows = self._db.list_media_activity(limit=max(1, min(limit, 200)))
        items: list[dict[str, Any]] = []
        for row in rows:
            viewed_at = _parse_datetime(row.get("last_viewed_at"))
            if viewed_at is None:
                continue
            last_page = _parse_epoch(row.get("last_page"))
            items.append(
                {
                    "mediaId": str(row.get("media_id") or ""),
                    "folderRaw": str(row.get("folder_raw") or ""),
                    "viewedAt": viewed_at,
                    "lastPage": last_page if last_page is not None and last_page > 0 else None,
                }
            )
        return items

    def record_media_activity(
        self,
        media_id: str | None,
        *,
        identity: dict[str, Any] | None = None,
        last_page: int | None = None,
        total_pages: int | None = None,
    ) -> dict[str, Any]:
        media = self.resolve_media_record(media_id, identity=identity)
        normalized_last_page = None
        if str(media.get("kind") or "") == "pdf" and last_page is not None:
            normalized_last_page = max(1, int(last_page))
            if total_pages is not None and int(total_pages) > 0:
                if normalized_last_page >= int(total_pages):
                    normalized_last_page = None

        now = _utcnow_iso()
        row = self._db.upsert_media_activity(
            str(media["media_id"]),
            viewed_at=now,
            last_page=normalized_last_page,
        )
        viewed_at = _parse_datetime(row.get("last_viewed_at")) or _parse_datetime(now)
        return {
            "mediaId": str(media["media_id"]),
            "folderRaw": str(media.get("folder_raw") or ""),
            "viewedAt": viewed_at,
            "lastPage": normalized_last_page,
        }

    def list_tag_master(
        self,
        *,
        category: str | None = None,
        contains: str | None = None,
        limit: int = 200,
    ) -> list[dict[str, Any]]:
        rows = self._db.list_tag_master()
        filtered: list[dict[str, Any]] = []
        contains_value = str(contains or "").strip()

        for row in rows:
            if category and row["category"] != category:
                continue
            if contains_value and not self._tag_aliases.matches_contains(
                str(row["category"]),
                str(row["name"]),
                contains_value,
            ):
                continue
            filtered.append(
                {
                    "tagId": row["tag_id"],
                    "name": row["name"],
                    "category": row["category"],
                }
            )
            if len(filtered) >= limit:
                break

        return filtered

    def delete_tag_master(self, tag_id: str) -> int:
        existing = self._db.get_tag_master(tag_id)
        if existing is None:
            raise not_found("Tag was not found")
        return self._db.delete_tag_master(tag_id)

    def backfill_configured_tag_aliases(self) -> dict[str, int]:
        if not self._tag_aliases.is_configured:
            return {"removedAliasCount": 0, "migratedLinkCount": 0}

        removed_alias_count = 0
        migrated_link_count = 0
        for row in self._db.list_tag_master():
            category = str(row.get("category") or "").strip()
            current_name = str(row.get("name") or "").strip()
            canonical_name = self._tag_aliases.canonicalize_name(category, current_name)
            if not category or not current_name or not canonical_name:
                continue
            if canonical_name == current_name:
                continue

            canonical_tag_id = self.ensure_exact_tag_id(
                category=category,
                raw_name=canonical_name,
                request_id="tag-alias-backfill",
            )
            if canonical_tag_id is None:
                continue

            alias_tag_id = str(row["tag_id"])
            if canonical_tag_id == alias_tag_id:
                continue

            media_ids = self._db.list_media_ids_for_tag(alias_tag_id)
            for media_id in media_ids:
                self._db.add_media_tag_link(media_id, canonical_tag_id)
            migrated_link_count += len(media_ids)
            removed_alias_count += self._db.delete_tag_master(alias_tag_id)

        return {
            "removedAliasCount": removed_alias_count,
            "migratedLinkCount": migrated_link_count,
        }

    def resolve_media_record(
        self,
        media_id: str | None,
        *,
        identity: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        if media_id:
            record = self._db.get_media_record(media_id)
            if record is not None:
                return record

        normalized_path = None
        aliases: list[str] = []
        if identity:
            normalized_path = identity.get("normalizedPath") or identity.get("normalized_path")
            raw_aliases = identity.get("aliases") or []
            aliases = [str(alias).strip() for alias in raw_aliases if str(alias).strip()]

        if normalized_path:
            record = self._db.get_media_record_by_normalized_path(str(normalized_path))
            if record is not None:
                return record

        for alias in aliases:
            record = self._db.get_media_record_by_path(alias)
            if record is not None:
                return record

            record = self._db.get_media_record_by_normalized_path(_normalize_path(alias))
            if record is not None:
                return record

        raise not_found("Media was not found")

    def resolve_media_id(
        self,
        media_id: str | None,
        *,
        identity: dict[str, Any] | None = None,
    ) -> str:
        return self.resolve_media_record(media_id, identity=identity)["media_id"]

    def get_tags_for_media(
        self,
        media_id: str,
        *,
        identity: dict[str, Any] | None = None,
    ) -> list[dict[str, Any]]:
        resolved_media_id = self.resolve_media_id(media_id, identity=identity)
        return [
            {
                "tagId": row["tag_id"],
                "name": row["name"],
                "category": row["category"],
            }
            for row in self._db.list_tags_for_media(resolved_media_id)
        ]

    def ensure_exact_tag_id(
        self,
        *,
        category: str,
        raw_name: str,
        request_id: str | None = None,
    ) -> str | None:
        resolved_request_id = _log_request_id(request_id)
        normalized_category = str(category or "").strip()
        raw_value = str(raw_name or "")
        incoming_name = raw_value.strip()
        name = self._tag_aliases.canonicalize_name(normalized_category, incoming_name)
        normalized_name = _normalize_name(name) if name else ""
        logger.info(
            '[TAG][RESOLVE][req:%s] category=%s rawName=%s canonicalName=%s normalizedName=%s lookup=exact',
            resolved_request_id,
            _log_value(normalized_category),
            _log_value(raw_value),
            _log_value(name),
            _log_value(normalized_name),
        )
        if not normalized_category or not name or not normalized_name:
            logger.info(
                '[TAG][RESOLVE][req:%s] category=%s rawName=%s canonicalName=%s normalizedName=%s found=false skipped=true reason=empty',
                resolved_request_id,
                _log_value(normalized_category),
                _log_value(raw_value),
                _log_value(name),
                _log_value(normalized_name),
            )
            return None

        try:
            existing = self._db.find_tag_exact(
                category=normalized_category,
                normalized_name=normalized_name,
            )
        except Exception:
            logger.exception(
                '[TAG][RESOLVE][req:%s] category=%s rawName=%s normalizedName=%s found=error',
                resolved_request_id,
                _log_value(normalized_category),
                _log_value(raw_value),
                _log_value(normalized_name),
            )
            raise
        if existing is not None:
            logger.info(
                '[TAG][RESOLVE][req:%s] category=%s rawName=%s normalizedName=%s found=true tagId=%s',
                resolved_request_id,
                _log_value(normalized_category),
                _log_value(raw_value),
                _log_value(normalized_name),
                _log_value(existing['tag_id']),
            )
            return str(existing['tag_id'])

        tag_id = f"{normalized_category}:{_fnv1a64_hex(f'{normalized_category}|{normalized_name}')[:12]}"
        logger.info(
            '[TAG][RESOLVE][req:%s] category=%s rawName=%s normalizedName=%s found=false action=create',
            resolved_request_id,
            _log_value(normalized_category),
            _log_value(raw_value),
            _log_value(normalized_name),
        )
        try:
            self._db.insert_tag(tag_id, name, normalized_category, normalized_name)
            logger.info(
                '[TAG][CREATE][req:%s] category=%s name=%s tagId=%s success=true',
                resolved_request_id,
                _log_value(normalized_category),
                _log_value(name),
                _log_value(tag_id),
            )
        except Exception:
            logger.exception(
                '[TAG][CREATE][req:%s] category=%s name=%s tagId=%s success=false',
                resolved_request_id,
                _log_value(normalized_category),
                _log_value(name),
                _log_value(tag_id),
            )
            raise
        inserted = self._db.find_tag_exact(
            category=normalized_category,
            normalized_name=normalized_name,
        )
        resolved_tag_id = str(inserted['tag_id']) if inserted is not None else tag_id
        logger.info(
            '[TAG][CREATE][req:%s] category=%s name=%s tagId=%s verified=true',
            resolved_request_id,
            _log_value(normalized_category),
            _log_value(name),
            _log_value(resolved_tag_id),
        )
        return resolved_tag_id

    def add_tags_to_media(
        self,
        media_id: str,
        tags: list[dict[str, str]],
        *,
        identity: dict[str, Any] | None = None,
        request_id: str | None = None,
    ) -> str:
        resolved_request_id = _log_request_id(request_id)
        resolved_media_id = self.resolve_media_id(media_id, identity=identity)
        success_count = 0
        failure_count = 0

        for tag in tags:
            category = str(tag.get('category') or '')
            name = str(tag.get('name') or '')
            try:
                tag_id = self.ensure_exact_tag_id(
                    category=category,
                    raw_name=name,
                    request_id=request_id,
                )
            except Exception:
                failure_count += 1
                logger.exception(
                    '[TAG][ATTACH][req:%s] itemId=%s category=%s name=%s success=false stage=resolve',
                    resolved_request_id,
                    _log_value(resolved_media_id),
                    _log_value(category),
                    _log_value(name),
                )
                raise
            if tag_id is None:
                logger.info(
                    '[TAG][ATTACH][req:%s] itemId=%s category=%s name=%s success=false skipped=true reason=empty',
                    resolved_request_id,
                    _log_value(resolved_media_id),
                    _log_value(category),
                    _log_value(name),
                )
                continue
            try:
                self._db.add_media_tag_link(resolved_media_id, tag_id)
                success_count += 1
                logger.info(
                    '[TAG][ATTACH][req:%s] itemId=%s tagId=%s category=%s name=%s success=true',
                    resolved_request_id,
                    _log_value(resolved_media_id),
                    _log_value(tag_id),
                    _log_value(category),
                    _log_value(name.strip()),
                )
            except Exception:
                failure_count += 1
                logger.exception(
                    '[TAG][ATTACH][req:%s] itemId=%s tagId=%s category=%s name=%s success=false',
                    resolved_request_id,
                    _log_value(resolved_media_id),
                    _log_value(tag_id),
                    _log_value(category),
                    _log_value(name),
                )
                raise

        logger.info(
            '[UPLOAD][RESULT][req:%s] itemId=%s tagAttachSuccessCount=%s tagAttachFailureCount=%s',
            resolved_request_id,
            _log_value(resolved_media_id),
            success_count,
            failure_count,
        )
        return resolved_media_id

    def replace_tags_for_media(
        self,
        media_id: str,
        tags: list[dict[str, str]],
        *,
        identity: dict[str, Any] | None = None,
    ) -> str:
        resolved_media_id = self.resolve_media_id(media_id, identity=identity)

        existing = [row["tag_id"] for row in self._db.list_tags_for_media(resolved_media_id)]
        if existing:
            self._db.remove_media_tag_links(resolved_media_id, existing)

        if tags:
            self.add_tags_to_media(resolved_media_id, tags)

        return resolved_media_id

    def remove_tags_from_media(
        self,
        media_id: str,
        tag_ids: list[str],
        *,
        identity: dict[str, Any] | None = None,
    ) -> str:
        resolved_media_id = self.resolve_media_id(media_id, identity=identity)
        self._db.remove_media_tag_links(resolved_media_id, tag_ids)
        return resolved_media_id

    def search_media(self, query: SearchQuery) -> tuple[list[dict[str, Any]], int]:
        folder_prefix = _normalize_path(query.folder_raw) if query.folder_raw else None
        rows = self._db.list_media_records(folder_prefix=folder_prefix, include_deleted=False)
        media_by_id = [self._row_to_media_dict(row) for row in rows if row["kind"] in {"image", "pdf"}]
        tags_by_media_id = self._db.list_tag_links_for_media_ids([row["mediaId"] for row in media_by_id])

        filtered = [
            row
            for row in media_by_id
            if self._matches_search(row, tags_by_media_id.get(row["mediaId"], []), query)
        ]

        total = len(filtered)
        sliced = filtered[query.offset : query.offset + query.limit]
        return self._attach_stats_to_media_items(sliced), total

    def list_untagged(
        self,
        *,
        folder_raw: str | None = None,
        limit: int = 50,
        offset: int = 0,
    ) -> tuple[list[dict[str, Any]], int]:
        folder_prefix = _normalize_path(folder_raw) if folder_raw else None
        rows = self._db.list_media_records(folder_prefix=folder_prefix, include_deleted=False)
        media = [self._row_to_media_dict(row) for row in rows if row["kind"] in {"image", "pdf"}]
        tag_map = self._db.list_tag_links_for_media_ids([row["mediaId"] for row in media])
        untagged = [row for row in media if not tag_map.get(row["mediaId"])]
        total = len(untagged)
        sliced = untagged[offset : offset + limit]
        return self._attach_stats_to_media_items(sliced), total

    def list_folder_children(
        self,
        folder_raw: str,
        *,
        limit: int,
        offset: int,
    ) -> tuple[list[dict[str, Any]], int]:
        folder_path = os.path.normpath(folder_raw)
        folder_norm = _normalize_path(folder_path)
        rows = self._db.list_media_records(folder_prefix=folder_norm, include_deleted=False)

        seen_folders: dict[str, dict[str, Any]] = {}
        files: list[dict[str, Any]] = []

        for row in rows:
            full_path = os.path.normpath(row["full_path"])
            try:
                relative = os.path.relpath(full_path, folder_path)
            except ValueError:
                continue

            if relative in {".", ""}:
                continue

            parts = Path(relative).parts
            if len(parts) > 1:
                child_folder = os.path.normpath(os.path.join(folder_path, parts[0]))
                seen_folders.setdefault(
                    _normalize_path(child_folder),
                    {
                        "entryId": child_folder,
                        "displayName": parts[0],
                        "folderRaw": folder_path,
                        "kind": "folder",
                        "mediaId": None,
                        "fullPath": child_folder,
                        "sizeBytes": None,
                        "modifiedAt": None,
                    },
                )
                continue

            files.append({"entryId": full_path, **self._row_to_media_dict(row)})

        combined = list(seen_folders.values()) + files
        combined.sort(
            key=lambda entry: (
                0 if entry["kind"] == "folder" else 1,
                entry["displayName"].casefold(),
            )
        )
        total = len(combined)
        return combined[offset : offset + limit], total

    def apply_rename(
        self,
        *,
        old_media_id: str | None,
        new_media_id: str | None,
        old_path: str | None,
        new_path: str | None,
    ) -> dict[str, Any]:
        if not old_path and not old_media_id:
            raise bad_request("oldPath or oldMediaId is required")
        if not new_path and not new_media_id:
            raise bad_request("newPath or newMediaId is required")

        current = self._db.get_media_record(old_media_id) if old_media_id else None
        if current is None and old_path:
            current = self._db.get_media_record_by_path(old_path)

        old_full_path = os.path.normpath(old_path or (current["full_path"] if current else ""))
        target_full_path = os.path.normpath(new_path or old_full_path)
        logger.info("[RENAME] request old=%s new=%s", old_full_path, target_full_path)

        if current is None:
            if not old_full_path or not os.path.isdir(old_full_path):
                raise not_found("Rename target was not found")

            if _normalize_path(old_full_path) == _normalize_path(target_full_path):
                logger.info("[MOVE] skipped same-file old=%s new=%s", old_full_path, target_full_path)
                return {
                    "entryId": target_full_path,
                    "displayName": os.path.basename(target_full_path),
                    "folderRaw": os.path.dirname(target_full_path),
                    "kind": "folder",
                    "mediaId": None,
                    "fullPath": target_full_path,
                    "sizeBytes": None,
                    "modifiedAt": None,
                }

            if os.path.exists(target_full_path):
                logger.warning("[RENAME] failed reason=duplicate-name old=%s new=%s", old_full_path, target_full_path)
                raise bad_request("A file or folder with the same name already exists")

            target_parent = os.path.dirname(target_full_path)
            if target_parent:
                os.makedirs(target_parent, exist_ok=True)
            shutil.move(old_full_path, target_full_path)

            descendants = self._db.list_media_records(
                folder_prefix=_normalize_path(old_full_path),
                include_deleted=True,
            )
            for row in descendants:
                current_full = os.path.normpath(str(row["full_path"]))
                relative = os.path.relpath(current_full, old_full_path)
                actual_path = os.path.normpath(os.path.join(target_full_path, relative))
                folder_raw = os.path.dirname(actual_path)
                display_name = os.path.basename(actual_path)
                stat = os.stat(actual_path) if os.path.exists(actual_path) else None
                size_bytes = stat.st_size if stat else row.get("size_bytes")
                modified_epoch_ms = int(stat.st_mtime * 1000) if stat else row.get("modified_epoch_ms")
                modified_at = (
                    datetime.fromtimestamp(stat.st_mtime, tz=timezone.utc).isoformat()
                    if stat
                    else row.get("modified_at")
                )
                final_media_id = build_media_id(
                    kind=str(row["kind"]),
                    full_path=actual_path,
                    folder_raw=folder_raw,
                    display_name=display_name,
                    size_bytes=size_bytes,
                    modified_epoch_ms=modified_epoch_ms,
                )
                updated = {
                    "media_id": final_media_id,
                    "folder_raw": folder_raw,
                    "relative_hint": display_name,
                    "display_name": display_name,
                    "full_path": actual_path,
                    "normalized_full_path": _normalize_path(actual_path),
                    "kind": row["kind"],
                    "mime_type": row.get("mime_type"),
                    "size_bytes": size_bytes,
                    "modified_at": modified_at,
                    "modified_epoch_ms": modified_epoch_ms,
                    "etag": row.get("etag"),
                    "is_deleted": row.get("is_deleted", 0),
                }
                self._db.upsert_media_record(updated)
                self._db.replace_media_id_references(str(row["media_id"]), final_media_id)
                if str(row["media_id"]) != final_media_id:
                    self._db.remove_media_record(str(row["media_id"]))

            logger.info("[RENAME] success old=%s new=%s", old_full_path, target_full_path)
            return {
                "entryId": target_full_path,
                "displayName": os.path.basename(target_full_path),
                "folderRaw": os.path.dirname(target_full_path),
                "kind": "folder",
                "mediaId": None,
                "fullPath": target_full_path,
                "sizeBytes": None,
                "modifiedAt": None,
            }

        old_full_path = os.path.normpath(old_path or current["full_path"])
        target_full_path = os.path.normpath(new_path or current["full_path"])
        if old_full_path != target_full_path and os.path.exists(old_full_path):
            if os.path.exists(target_full_path):
                if _same_file(old_full_path, target_full_path):
                    logger.info("[MOVE] skipped same-file old=%s new=%s", old_full_path, target_full_path)
                else:
                    logger.warning("[RENAME] failed reason=duplicate-name old=%s new=%s", old_full_path, target_full_path)
                    raise bad_request("A file or folder with the same name already exists")
            else:
                target_parent = os.path.dirname(target_full_path)
                if target_parent:
                    os.makedirs(target_parent, exist_ok=True)
                os.replace(old_full_path, target_full_path)

        actual_path = target_full_path
        kind = current["kind"]
        folder_raw = os.path.dirname(actual_path)
        display_name = os.path.basename(actual_path)
        stat = os.stat(actual_path) if os.path.exists(actual_path) else None
        size_bytes = stat.st_size if stat else current.get("size_bytes")
        modified_epoch_ms = int(stat.st_mtime * 1000) if stat else current.get("modified_epoch_ms")
        modified_at = (
            datetime.fromtimestamp(stat.st_mtime, tz=timezone.utc).isoformat()
            if stat
            else current.get("modified_at")
        )
        computed_media_id = build_media_id(
            kind=kind,
            full_path=actual_path,
            folder_raw=folder_raw,
            display_name=display_name,
            size_bytes=size_bytes,
            modified_epoch_ms=modified_epoch_ms,
        )
        if new_media_id and new_media_id != computed_media_id:
            logger.warning(
                "[RENAME] ignoring mismatched new media id old=%s provided=%s computed=%s",
                old_full_path,
                new_media_id,
                computed_media_id,
            )
        final_media_id = computed_media_id

        updated = {
            "media_id": final_media_id,
            "folder_raw": folder_raw,
            "relative_hint": display_name,
            "display_name": display_name,
            "full_path": actual_path,
            "normalized_full_path": _normalize_path(actual_path),
            "kind": kind,
            "mime_type": current.get("mime_type"),
            "size_bytes": size_bytes,
            "modified_at": modified_at,
            "modified_epoch_ms": modified_epoch_ms,
            "etag": current.get("etag"),
            "is_deleted": 0,
        }
        self._db.upsert_media_record(updated)
        self._db.replace_media_id_references(current["media_id"], final_media_id)
        if current["media_id"] != final_media_id:
            self._db.remove_media_record(current["media_id"])
        logger.info("[RENAME] success old=%s new=%s", old_full_path, target_full_path)
        return self._row_to_media_dict(updated)

    def apply_delete(self, items: list[dict[str, Any]], hard_delete: bool = False) -> int:
        target_ids: list[str] = []
        target_paths: list[str] = []
        deleted_count = 0

        for item in items:
            media_id = item.get("mediaId")
            path = item.get("path")
            record = self._db.get_media_record(media_id) if media_id else None
            if record is None and path:
                record = self._db.get_media_record_by_path(path)
            if record is None:
                raw_path = str(path or "").strip()
                if not raw_path or not os.path.isdir(raw_path):
                    continue

                normalized_folder = _normalize_path(raw_path)
                descendants = self._db.list_media_records(
                    folder_prefix=normalized_folder,
                    include_deleted=False,
                )
                deleted_count += 1
                target_ids.extend(str(row["media_id"]) for row in descendants)
                target_paths.extend(str(row["normalized_full_path"]) for row in descendants)

                if hard_delete and os.path.exists(raw_path):
                    shutil.rmtree(raw_path)
                continue

            target_ids.append(record["media_id"])
            target_paths.append(record["normalized_full_path"])
            deleted_count += 1

            if hard_delete:
                full_path = record["full_path"]
                if os.path.exists(full_path):
                    os.remove(full_path)

        if target_ids:
            deduped_ids = list(dict.fromkeys(target_ids))
            self._db.mark_deleted_by_ids(deduped_ids, is_deleted=True)
        elif target_paths:
            deduped_paths = list(dict.fromkeys(target_paths))
            self._db.mark_deleted_by_paths(deduped_paths, is_deleted=True)
        return deleted_count

    def organize_media_by_tags(
        self,
        *,
        library_root: str,
        media_ids: list[str] | None = None,
    ) -> dict[str, str]:
        moved: dict[str, str] = {}
        normalized_root = _normalize_path(library_root)
        candidate_media_ids = media_ids
        if not candidate_media_ids:
            candidate_media_ids = [
                str(row["media_id"])
                for row in self._db.list_media_records(
                    folder_prefix=normalized_root,
                    include_deleted=False,
                )
                if str(row.get("kind") or "") in {"image", "pdf"}
            ]

        for media_id in candidate_media_ids:
            current = self._db.get_media_record(media_id)
            if current is None or current.get("is_deleted"):
                continue

            source_path = os.path.normpath(current["full_path"])
            source_norm = _normalize_path(source_path)
            if source_norm != normalized_root and not source_norm.startswith(normalized_root + "\\"):
                continue

            tags = self.get_tags_for_media(current["media_id"])
            artist_names = _tag_names_for_category(tags, "artist")
            series_name = _pick_first_tag_name(tags, "series")
            destination_dir = self._calc_library_dest_dir(
                library_root=library_root,
                artist_names=artist_names,
                series_name=series_name,
            )
            file_name = os.path.basename(source_path)
            candidate_path = os.path.normpath(os.path.join(destination_dir, file_name))
            if _normalize_path(source_path) == _normalize_path(candidate_path):
                continue

            target_path = candidate_path
            if os.path.exists(candidate_path):
                if _same_file(source_path, candidate_path):
                    logger.info("[MOVE] skipped same-file old=%s new=%s", source_path, candidate_path)
                    continue
                logger.warning("[TAG-ORGANIZE] conflict source=%s target=%s", source_path, candidate_path)
                continue

            updated = self.apply_rename(
                old_media_id=current["media_id"],
                new_media_id=None,
                old_path=source_path,
                new_path=target_path,
            )
            _remove_empty_ancestor_dirs(
                start_dir=os.path.dirname(source_path),
                stop_at=library_root,
            )
            moved[source_path] = updated["fullPath"]

        _remove_empty_legacy_author_dirs(library_root)

        return moved

    def _calc_library_dest_dir(
        self,
        *,
        library_root: str,
        artist_names: list[str],
        series_name: str | None,
    ) -> str:
        artist = _sanitize_dir_name(artist_names[0]) if len(artist_names) == 1 else None
        series = _sanitize_dir_name(series_name or "") if series_name else None

        if artist:
            return os.path.join(library_root, "\u4f5c\u8005", artist)

        if series:
            return os.path.join(library_root, "\u30b7\u30ea\u30fc\u30ba", series)

        return os.path.join(library_root, "\u4e0d\u660e")

    def _matches_search(
        self,
        media: dict[str, Any],
        tags: list[dict[str, Any]],
        query: SearchQuery,
    ) -> bool:
        def tag_matches(category: str, needle: str) -> bool:
            needle_norms = [
                _normalize_name(value)
                for value in self._tag_aliases.equivalent_names(
                    category,
                    needle,
                    partial=query.partial,
                )
            ]
            needle_norms = [value for value in needle_norms if value]
            if not needle_norms:
                return False
            for tag in tags:
                if tag["category"] != category:
                    continue
                value = tag["normalized_name"]
                if query.partial:
                    if any(needle_norm in value for needle_norm in needle_norms):
                        return True
                elif value in needle_norms:
                    return True
            return False

        if query.artist and not tag_matches("artist", query.artist):
            return False
        if query.series and not tag_matches("series", query.series):
            return False
        if query.character and not tag_matches("character", query.character):
            return False
        if query.media_type:
            media_type_norm = _normalize_name(query.media_type)
            kind_norm = _normalize_name(str(media["kind"]))
            if media_type_norm != kind_norm and not tag_matches("mediaType", query.media_type):
                return False

        name_norm = _normalize_name(media["displayName"])
        if query.name:
            target = _normalize_name(query.name)
            if query.partial:
                if target not in name_norm:
                    return False
            elif target != name_norm:
                return False

        if query.q:
            q_norms = [
                _normalize_name(value)
                for value in self._tag_aliases.equivalent_names_across_categories(
                    query.q,
                    partial=True,
                )
            ]
            q_norms = [value for value in q_norms if value]
            if not any(q_norm in name_norm for q_norm in q_norms):
                if not any(
                    any(q_norm in tag["normalized_name"] for q_norm in q_norms)
                    for tag in tags
                ):
                    return False

        return True

    def _row_to_media_dict(self, row: dict[str, Any]) -> dict[str, Any]:
        return {
            "mediaId": row["media_id"],
            "displayName": row["display_name"],
            "folderRaw": row["folder_raw"],
            "kind": row["kind"],
            "fullPath": row["full_path"],
            "sizeBytes": row["size_bytes"],
            "modifiedAt": _parse_datetime(row["modified_at"]),
            "mimeType": row["mime_type"],
            "etag": row["etag"],
            "isDeleted": bool(row["is_deleted"]),
            "modifiedEpochMs": _parse_epoch(row.get("modified_epoch_ms")),
        }

    def _stats_row_to_dict(self, row: dict[str, Any] | None) -> dict[str, Any] | None:
        if row is None:
            return None
        added_at = _parse_datetime(row.get("added_at"))
        if added_at is None:
            return None
        return {
            "addedAt": added_at,
            "lastViewedAt": _parse_datetime(row.get("last_viewed_at")),
            "viewCount": _parse_epoch(row.get("view_count")) or 0,
        }

    def _ensure_stats_for_media_ids(self, media_ids: list[str]) -> dict[str, dict[str, Any]]:
        unique_ids = list(dict.fromkeys(str(media_id).strip() for media_id in media_ids if str(media_id).strip()))
        if not unique_ids:
            return {}
        self._db.ensure_media_stats(unique_ids, added_at=_utcnow_iso())
        raw_stats = self._db.list_media_stats(unique_ids)
        return {
            media_id: stats
            for media_id, stats in (
                (media_id, self._stats_row_to_dict(row))
                for media_id, row in raw_stats.items()
            )
            if stats is not None
        }

    def _attach_stats_to_media_items(
        self,
        items: list[dict[str, Any]],
    ) -> list[dict[str, Any]]:
        if not items:
            return items
        stats_by_media_id = self._ensure_stats_for_media_ids(
            [
                str(item.get("mediaId") or "")
                for item in items
                if str(item.get("kind") or "") == "pdf"
            ]
        )
        enriched: list[dict[str, Any]] = []
        for item in items:
            enriched_item = dict(item)
            media_id = str(enriched_item.get("mediaId") or "").strip()
            if media_id and str(enriched_item.get("kind") or "") == "pdf":
                enriched_item["stats"] = stats_by_media_id.get(media_id)
            else:
                enriched_item["stats"] = None
            enriched.append(enriched_item)
        return enriched









