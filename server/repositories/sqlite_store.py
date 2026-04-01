from __future__ import annotations

import sqlite3
import threading
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterable


class SqliteStore:
    def __init__(self, db_path: Path) -> None:
        self._db_path = Path(db_path)
        self._db_path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._conn = sqlite3.connect(self._db_path, check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA journal_mode=WAL;")
        self._conn.execute("PRAGMA foreign_keys=ON;")

    @contextmanager
    def _cursor(self) -> Iterable[sqlite3.Cursor]:
        with self._lock:
            cursor = self._conn.cursor()
            try:
                yield cursor
                self._conn.commit()
            except Exception:
                self._conn.rollback()
                raise
            finally:
                cursor.close()

    def init_schema(self) -> None:
        with self._cursor() as cur:
            cur.executescript(
                """
                CREATE TABLE IF NOT EXISTS media_records (
                    media_id TEXT PRIMARY KEY,
                    folder_raw TEXT NOT NULL,
                    relative_hint TEXT,
                    display_name TEXT NOT NULL,
                    full_path TEXT NOT NULL UNIQUE,
                    normalized_full_path TEXT NOT NULL UNIQUE,
                    kind TEXT NOT NULL,
                    mime_type TEXT,
                    size_bytes INTEGER,
                    modified_at TEXT,
                    modified_epoch_ms INTEGER,
                    etag TEXT,
                    is_deleted INTEGER NOT NULL DEFAULT 0
                );

                CREATE INDEX IF NOT EXISTS idx_media_folder_raw
                    ON media_records(folder_raw);
                CREATE INDEX IF NOT EXISTS idx_media_norm_full_path
                    ON media_records(normalized_full_path);
                CREATE INDEX IF NOT EXISTS idx_media_is_deleted
                    ON media_records(is_deleted);

                CREATE TABLE IF NOT EXISTS tag_master (
                    tag_id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    category TEXT NOT NULL,
                    normalized_name TEXT NOT NULL,
                    UNIQUE(category, normalized_name)
                );

                CREATE TABLE IF NOT EXISTS media_tag_links (
                    media_id TEXT NOT NULL,
                    tag_id TEXT NOT NULL,
                    PRIMARY KEY (media_id, tag_id),
                    FOREIGN KEY (media_id) REFERENCES media_records(media_id) ON DELETE CASCADE,
                    FOREIGN KEY (tag_id) REFERENCES tag_master(tag_id) ON DELETE CASCADE
                );

                CREATE TABLE IF NOT EXISTS indexed_folders (
                    folder_raw TEXT PRIMARY KEY,
                    normalized_folder_raw TEXT NOT NULL UNIQUE,
                    display_name TEXT NOT NULL,
                    last_scanned_at TEXT
                );
                """
            )

    def close(self) -> None:
        with self._lock:
            self._conn.close()

    def upsert_media_record(self, record: dict[str, Any]) -> None:
        with self._cursor() as cur:
            cur.execute(
                """
                INSERT INTO media_records (
                    media_id,
                    folder_raw,
                    relative_hint,
                    display_name,
                    full_path,
                    normalized_full_path,
                    kind,
                    mime_type,
                    size_bytes,
                    modified_at,
                    modified_epoch_ms,
                    etag,
                    is_deleted
                )
                VALUES (
                    :media_id,
                    :folder_raw,
                    :relative_hint,
                    :display_name,
                    :full_path,
                    :normalized_full_path,
                    :kind,
                    :mime_type,
                    :size_bytes,
                    :modified_at,
                    :modified_epoch_ms,
                    :etag,
                    :is_deleted
                )
                ON CONFLICT(media_id) DO UPDATE SET
                    folder_raw = excluded.folder_raw,
                    relative_hint = excluded.relative_hint,
                    display_name = excluded.display_name,
                    full_path = excluded.full_path,
                    normalized_full_path = excluded.normalized_full_path,
                    kind = excluded.kind,
                    mime_type = excluded.mime_type,
                    size_bytes = excluded.size_bytes,
                    modified_at = excluded.modified_at,
                    modified_epoch_ms = excluded.modified_epoch_ms,
                    etag = excluded.etag,
                    is_deleted = excluded.is_deleted
                """,
                record,
            )

    def remove_media_record(self, media_id: str) -> None:
        with self._cursor() as cur:
            cur.execute("DELETE FROM media_records WHERE media_id = ?", (media_id,))

    def get_media_record(self, media_id: str) -> dict[str, Any] | None:
        with self._cursor() as cur:
            row = cur.execute(
                "SELECT * FROM media_records WHERE media_id = ?",
                (media_id,),
            ).fetchone()
        return dict(row) if row else None

    def get_media_record_by_path(self, full_path: str) -> dict[str, Any] | None:
        with self._cursor() as cur:
            row = cur.execute(
                "SELECT * FROM media_records WHERE full_path = ?",
                (full_path,),
            ).fetchone()
        return dict(row) if row else None

    def get_media_record_by_normalized_path(
        self,
        normalized_full_path: str,
    ) -> dict[str, Any] | None:
        with self._cursor() as cur:
            row = cur.execute(
                "SELECT * FROM media_records WHERE normalized_full_path = ?",
                (normalized_full_path,),
            ).fetchone()
        return dict(row) if row else None

    def list_media_records(
        self,
        *,
        folder_prefix: str | None = None,
        include_deleted: bool = False,
    ) -> list[dict[str, Any]]:
        sql = "SELECT * FROM media_records"
        params: list[Any] = []
        clauses: list[str] = []

        if not include_deleted:
            clauses.append("is_deleted = 0")

        if folder_prefix:
            clauses.append("(normalized_full_path = ? OR normalized_full_path LIKE ?)")
            params.append(folder_prefix)
            params.append(f"{folder_prefix}\\%")

        if clauses:
            sql += " WHERE " + " AND ".join(clauses)

        sql += " ORDER BY folder_raw COLLATE NOCASE, display_name COLLATE NOCASE"

        with self._cursor() as cur:
            rows = cur.execute(sql, params).fetchall()
        return [dict(row) for row in rows]

    def mark_deleted_by_ids(self, media_ids: list[str], is_deleted: bool = True) -> None:
        if not media_ids:
            return
        placeholders = ",".join("?" for _ in media_ids)
        with self._cursor() as cur:
            cur.execute(
                f"UPDATE media_records SET is_deleted = ? WHERE media_id IN ({placeholders})",
                [1 if is_deleted else 0, *media_ids],
            )

    def mark_deleted_by_paths(
        self,
        normalized_paths: list[str],
        is_deleted: bool = True,
    ) -> None:
        if not normalized_paths:
            return
        placeholders = ",".join("?" for _ in normalized_paths)
        with self._cursor() as cur:
            cur.execute(
                f"""
                UPDATE media_records
                   SET is_deleted = ?
                 WHERE normalized_full_path IN ({placeholders})
                """,
                [1 if is_deleted else 0, *normalized_paths],
            )

    def upsert_indexed_folder(
        self,
        folder_raw: str,
        normalized_folder_raw: str,
        display_name: str,
        last_scanned_at: str | None,
    ) -> None:
        with self._cursor() as cur:
            cur.execute(
                """
                INSERT INTO indexed_folders (
                    folder_raw,
                    normalized_folder_raw,
                    display_name,
                    last_scanned_at
                )
                VALUES (?, ?, ?, ?)
                ON CONFLICT(folder_raw) DO UPDATE SET
                    normalized_folder_raw = excluded.normalized_folder_raw,
                    display_name = excluded.display_name,
                    last_scanned_at = excluded.last_scanned_at
                """,
                (folder_raw, normalized_folder_raw, display_name, last_scanned_at),
            )

    def list_indexed_folders(self) -> list[dict[str, Any]]:
        with self._cursor() as cur:
            rows = cur.execute(
                """
                SELECT *
                  FROM indexed_folders
              ORDER BY folder_raw COLLATE NOCASE
                """
            ).fetchall()
        return [dict(row) for row in rows]

    def find_tag_exact(
        self,
        *,
        category: str,
        normalized_name: str,
    ) -> dict[str, Any] | None:
        with self._cursor() as cur:
            row = cur.execute(
                """
                SELECT *
                  FROM tag_master
                 WHERE category = ?
                   AND normalized_name = ?
                 LIMIT 1
                """,
                (category, normalized_name),
            ).fetchone()
        return dict(row) if row else None

    def insert_tag(
        self,
        tag_id: str,
        name: str,
        category: str,
        normalized_name: str,
    ) -> None:
        with self._cursor() as cur:
            cur.execute(
                """
                INSERT INTO tag_master (tag_id, name, category, normalized_name)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(category, normalized_name) DO UPDATE SET
                    name = excluded.name,
                    category = excluded.category,
                    normalized_name = excluded.normalized_name
                """,
                (tag_id, name, category, normalized_name),
            )

    def ensure_tag(self, tag_id: str, name: str, category: str, normalized_name: str) -> None:
        self.insert_tag(tag_id, name, category, normalized_name)

    def list_tag_master(self) -> list[dict[str, Any]]:
        with self._cursor() as cur:
            rows = cur.execute(
                """
                SELECT *
                  FROM tag_master
              ORDER BY category COLLATE NOCASE, name COLLATE NOCASE
                """
            ).fetchall()
        return [dict(row) for row in rows]

    def get_tag_master(self, tag_id: str) -> dict[str, Any] | None:
        with self._cursor() as cur:
            row = cur.execute(
                "SELECT * FROM tag_master WHERE tag_id = ?",
                (tag_id,),
            ).fetchone()
        return dict(row) if row else None

    def delete_tag_master(self, tag_id: str) -> int:
        with self._cursor() as cur:
            cur.execute("DELETE FROM media_tag_links WHERE tag_id = ?", (tag_id,))
            result = cur.execute("DELETE FROM tag_master WHERE tag_id = ?", (tag_id,))
        return int(result.rowcount or 0)

    def list_tags_for_media(self, media_id: str) -> list[dict[str, Any]]:
        with self._cursor() as cur:
            rows = cur.execute(
                """
                SELECT tm.*
                  FROM media_tag_links mtl
                  JOIN tag_master tm ON tm.tag_id = mtl.tag_id
                 WHERE mtl.media_id = ?
              ORDER BY tm.category COLLATE NOCASE, tm.name COLLATE NOCASE
                """,
                (media_id,),
            ).fetchall()
        return [dict(row) for row in rows]

    def list_tag_links_for_media_ids(self, media_ids: list[str]) -> dict[str, list[dict[str, Any]]]:
        if not media_ids:
            return {}
        placeholders = ",".join("?" for _ in media_ids)
        with self._cursor() as cur:
            rows = cur.execute(
                f"""
                SELECT mtl.media_id, tm.tag_id, tm.name, tm.category, tm.normalized_name
                  FROM media_tag_links mtl
                  JOIN tag_master tm ON tm.tag_id = mtl.tag_id
                 WHERE mtl.media_id IN ({placeholders})
              ORDER BY tm.category COLLATE NOCASE, tm.name COLLATE NOCASE
                """,
                media_ids,
            ).fetchall()

        out: dict[str, list[dict[str, Any]]] = {}
        for row in rows:
            item = dict(row)
            media_id = item.pop("media_id")
            out.setdefault(media_id, []).append(item)
        return out

    def add_media_tag_link(self, media_id: str, tag_id: str) -> None:
        with self._cursor() as cur:
            cur.execute(
                """
                INSERT OR IGNORE INTO media_tag_links (media_id, tag_id)
                VALUES (?, ?)
                """,
                (media_id, tag_id),
            )

    def remove_media_tag_links(self, media_id: str, tag_ids: list[str]) -> None:
        if not tag_ids:
            return
        placeholders = ",".join("?" for _ in tag_ids)
        with self._cursor() as cur:
            cur.execute(
                f"""
                DELETE FROM media_tag_links
                 WHERE media_id = ?
                   AND tag_id IN ({placeholders})
                """,
                [media_id, *tag_ids],
            )

    def replace_media_id_references(self, old_media_id: str, new_media_id: str) -> None:
        with self._cursor() as cur:
            rows = cur.execute(
                "SELECT tag_id FROM media_tag_links WHERE media_id = ?",
                (old_media_id,),
            ).fetchall()

            for row in rows:
                cur.execute(
                    """
                    INSERT OR IGNORE INTO media_tag_links (media_id, tag_id)
                    VALUES (?, ?)
                    """,
                    (new_media_id, row["tag_id"]),
                )

            cur.execute(
                "DELETE FROM media_tag_links WHERE media_id = ?",
                (old_media_id,),
            )

