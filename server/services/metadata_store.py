from __future__ import annotations

import os
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from server.core.errors import bad_request, not_found
from server.repositories.sqlite_store import SqliteStore


def _normalize_name(name: str) -> str:
    return name.strip().casefold()


def _normalize_path(raw: str) -> str:
    normalized = os.path.normpath(raw).replace("/", "\\")
    return normalized.casefold()


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


def _unique_path(directory: str, file_name: str) -> str:
    base = Path(file_name).stem
    suffix = Path(file_name).suffix
    index = 1
    candidate = os.path.join(directory, file_name)
    while os.path.exists(candidate):
        candidate = os.path.join(directory, f"{base} ({index}){suffix}")
        index += 1
        if index > 999:
            return os.path.join(directory, f"{base}_{int(datetime.now(tz=timezone.utc).timestamp() * 1000)}{suffix}")
    return candidate


def _pick_first_tag_name(tags: list[dict[str, Any]], category: str) -> str | None:
    for tag in tags:
        if tag.get("category") != category:
            continue
        name = str(tag.get("name") or "").strip()
        if name:
            return name
    return None


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
    def __init__(self, sqlite_store: SqliteStore) -> None:
        self._db = sqlite_store

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
            raise not_found("メディアが見つかりません")
        return self._row_to_media_dict(row)

    def list_tag_master(
        self,
        *,
        category: str | None = None,
        contains: str | None = None,
        limit: int = 200,
    ) -> list[dict[str, Any]]:
        rows = self._db.list_tag_master()
        filtered: list[dict[str, Any]] = []
        contains_norm = _normalize_name(contains) if contains else None

        for row in rows:
            if category and row["category"] != category:
                continue
            if contains_norm and contains_norm not in row["normalized_name"]:
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

        raise not_found("メディアが見つかりません")

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
    ) -> str | None:
        normalized_category = str(category or "").strip()
        name = str(raw_name or "").strip()
        if not normalized_category or not name:
            return None

        normalized_name = _normalize_name(name)
        if not normalized_name:
            return None

        existing = self._db.find_tag_exact(
            category=normalized_category,
            normalized_name=normalized_name,
        )
        if existing is not None:
            return str(existing["tag_id"])

        tag_id = f"{normalized_category}:{_fnv1a64_hex(f'{normalized_category}|{normalized_name}')[:12]}"
        self._db.insert_tag(tag_id, name, normalized_category, normalized_name)
        inserted = self._db.find_tag_exact(
            category=normalized_category,
            normalized_name=normalized_name,
        )
        return str(inserted["tag_id"]) if inserted is not None else tag_id

    def add_tags_to_media(
        self,
        media_id: str,
        tags: list[dict[str, str]],
        *,
        identity: dict[str, Any] | None = None,
    ) -> str:
        resolved_media_id = self.resolve_media_id(media_id, identity=identity)

        for tag in tags:
            tag_id = self.ensure_exact_tag_id(
                category=str(tag.get("category") or ""),
                raw_name=str(tag.get("name") or ""),
            )
            if tag_id is None:
                continue
            self._db.add_media_tag_link(resolved_media_id, tag_id)

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
        return sliced, total

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
        return untagged[offset : offset + limit], total

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
            raise bad_request("oldPath または oldMediaId が必要です")
        if not new_path and not new_media_id:
            raise bad_request("newPath または newMediaId が必要です")

        current = self._db.get_media_record(old_media_id) if old_media_id else None
        if current is None and old_path:
            current = self._db.get_media_record_by_path(old_path)
        if current is None:
            raise not_found("リネーム対象のメディアが見つかりません")

        old_full_path = os.path.normpath(old_path or current["full_path"])
        target_full_path = os.path.normpath(new_path or current["full_path"])
        if old_full_path != target_full_path and os.path.exists(old_full_path):
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
        final_media_id = new_media_id or build_media_id(
            kind=kind,
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
        return self._row_to_media_dict(updated)

    def apply_delete(self, items: list[dict[str, Any]], hard_delete: bool = False) -> int:
        target_ids: list[str] = []
        target_paths: list[str] = []

        for item in items:
            media_id = item.get("mediaId")
            path = item.get("path")
            record = self._db.get_media_record(media_id) if media_id else None
            if record is None and path:
                record = self._db.get_media_record_by_path(path)
            if record is None:
                continue

            target_ids.append(record["media_id"])
            target_paths.append(record["normalized_full_path"])

            if hard_delete:
                full_path = record["full_path"]
                if os.path.exists(full_path):
                    os.remove(full_path)

        self._db.mark_deleted_by_ids(target_ids, is_deleted=True)
        if not target_ids and target_paths:
            self._db.mark_deleted_by_paths(target_paths, is_deleted=True)
        return len(target_ids)

    def organize_media_by_tags(
        self,
        *,
        library_root: str,
        media_ids: list[str],
    ) -> dict[str, str]:
        moved: dict[str, str] = {}
        normalized_root = _normalize_path(library_root)

        for media_id in media_ids:
            current = self._db.get_media_record(media_id)
            if current is None or current.get("is_deleted"):
                continue

            source_path = os.path.normpath(current["full_path"])
            source_norm = _normalize_path(source_path)
            if source_norm != normalized_root and not source_norm.startswith(normalized_root + "\\"):
                continue

            tags = self.get_tags_for_media(current["media_id"])
            artist_name = _pick_first_tag_name(tags, "artist")
            series_name = _pick_first_tag_name(tags, "series")
            if not artist_name and not series_name:
                continue

            destination_dir = self._calc_library_dest_dir(
                library_root=library_root,
                artist_name=artist_name,
                series_name=series_name,
            )
            file_name = os.path.basename(source_path)
            candidate_path = os.path.normpath(os.path.join(destination_dir, file_name))
            if _normalize_path(source_path) == _normalize_path(candidate_path):
                continue

            if os.path.exists(candidate_path):
                target_path = _unique_path(destination_dir, file_name)
            else:
                target_path = candidate_path

            updated = self.apply_rename(
                old_media_id=current["media_id"],
                new_media_id=None,
                old_path=source_path,
                new_path=target_path,
            )
            moved[source_path] = updated["fullPath"]

        return moved

    def _calc_library_dest_dir(
        self,
        *,
        library_root: str,
        artist_name: str | None,
        series_name: str | None,
    ) -> str:
        artist = _sanitize_dir_name(artist_name or "") if artist_name else None
        series = _sanitize_dir_name(series_name or "") if series_name else None

        if artist:
            if series:
                return os.path.join(library_root, "\u4f5c\u8005\u5225", artist, series)
            return os.path.join(library_root, "\u4f5c\u8005\u5225", artist)

        if series:
            return os.path.join(library_root, "\u30b7\u30ea\u30fc\u30ba", series)

        return library_root

    def _matches_search(
        self,
        media: dict[str, Any],
        tags: list[dict[str, Any]],
        query: SearchQuery,
    ) -> bool:
        def tag_matches(category: str, needle: str) -> bool:
            needle_norm = _normalize_name(needle)
            for tag in tags:
                if tag["category"] != category:
                    continue
                value = tag["normalized_name"]
                if query.partial:
                    if needle_norm in value:
                        return True
                elif needle_norm == value:
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
            q_norm = _normalize_name(query.q)
            if q_norm not in name_norm:
                if not any(q_norm in tag["normalized_name"] for tag in tags):
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




