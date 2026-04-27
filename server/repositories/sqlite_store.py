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

                CREATE TABLE IF NOT EXISTS media_stats (
                    media_id TEXT PRIMARY KEY,
                    added_at TEXT NOT NULL,
                    last_viewed_at TEXT,
                    view_count INTEGER NOT NULL DEFAULT 0,
                    FOREIGN KEY (media_id) REFERENCES media_records(media_id) ON DELETE CASCADE
                );

                CREATE INDEX IF NOT EXISTS idx_media_stats_added_at
                    ON media_stats(added_at);
                CREATE INDEX IF NOT EXISTS idx_media_stats_last_viewed_at
                    ON media_stats(last_viewed_at);
                CREATE INDEX IF NOT EXISTS idx_media_stats_view_count
                    ON media_stats(view_count);

                CREATE TABLE IF NOT EXISTS media_activity (
                    media_id TEXT PRIMARY KEY,
                    last_viewed_at TEXT NOT NULL,
                    last_page INTEGER,
                    FOREIGN KEY (media_id) REFERENCES media_records(media_id) ON DELETE CASCADE
                );

                CREATE INDEX IF NOT EXISTS idx_media_activity_last_viewed_at
                    ON media_activity(last_viewed_at);

                CREATE TABLE IF NOT EXISTS reading_progress (
                    media_id TEXT PRIMARY KEY,
                    current_page INTEGER NOT NULL,
                    total_pages INTEGER,
                    progress REAL NOT NULL DEFAULT 0,
                    last_read_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    FOREIGN KEY (media_id) REFERENCES media_records(media_id) ON DELETE CASCADE
                );

                CREATE INDEX IF NOT EXISTS idx_reading_progress_last_read_at
                    ON reading_progress(last_read_at);
                CREATE INDEX IF NOT EXISTS idx_reading_progress_updated_at
                    ON reading_progress(updated_at);

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

                CREATE TABLE IF NOT EXISTS media_favorites (
                    media_id TEXT PRIMARY KEY,
                    updated_at TEXT NOT NULL,
                    FOREIGN KEY (media_id) REFERENCES media_records(media_id) ON DELETE CASCADE
                );

                CREATE INDEX IF NOT EXISTS idx_media_favorites_updated_at
                    ON media_favorites(updated_at);

                INSERT INTO reading_progress (
                    media_id,
                    current_page,
                    total_pages,
                    progress,
                    last_read_at,
                    updated_at
                )
                SELECT
                    legacy.media_id,
                    CASE
                        WHEN legacy.last_page IS NOT NULL AND legacy.last_page > 0 THEN legacy.last_page
                        ELSE 1
                    END,
                    NULL,
                    0,
                    legacy.last_viewed_at,
                    legacy.last_viewed_at
                FROM media_activity AS legacy
                LEFT JOIN reading_progress AS progress
                    ON progress.media_id = legacy.media_id
                WHERE progress.media_id IS NULL;
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

    def ensure_media_stats(self, media_ids: list[str], *, added_at: str) -> None:
        unique_ids = list(
            dict.fromkeys(
                str(media_id).strip()
                for media_id in media_ids
                if str(media_id).strip()
            )
        )
        if not unique_ids:
            return
        with self._cursor() as cur:
            cur.executemany(
                """
                INSERT OR IGNORE INTO media_stats (
                    media_id,
                    added_at,
                    last_viewed_at,
                    view_count
                )
                VALUES (?, ?, NULL, 0)
                """,
                [(media_id, added_at) for media_id in unique_ids],
            )

    def get_media_stats(self, media_id: str) -> dict[str, Any] | None:
        with self._cursor() as cur:
            row = cur.execute(
                """
                SELECT media_id, added_at, last_viewed_at, view_count
                  FROM media_stats
                 WHERE media_id = ?
                """,
                (media_id,),
            ).fetchone()
        return dict(row) if row else None

    def list_media_stats(self, media_ids: list[str]) -> dict[str, dict[str, Any]]:
        unique_ids = list(
            dict.fromkeys(
                str(media_id).strip()
                for media_id in media_ids
                if str(media_id).strip()
            )
        )
        if not unique_ids:
            return {}
        placeholders = ",".join("?" for _ in unique_ids)
        with self._cursor() as cur:
            rows = cur.execute(
                f"""
                SELECT media_id, added_at, last_viewed_at, view_count
                  FROM media_stats
                 WHERE media_id IN ({placeholders})
                """,
                unique_ids,
            ).fetchall()
        out: dict[str, dict[str, Any]] = {}
        for row in rows:
            item = dict(row)
            media_id = str(item.pop("media_id"))
            out[media_id] = item
        return out

    def increment_media_view(
        self,
        media_id: str,
        *,
        viewed_at: str,
        added_at: str,
    ) -> dict[str, Any]:
        with self._cursor() as cur:
            cur.execute(
                """
                INSERT INTO media_stats (
                    media_id,
                    added_at,
                    last_viewed_at,
                    view_count
                )
                VALUES (?, ?, ?, 1)
                ON CONFLICT(media_id) DO UPDATE SET
                    last_viewed_at = excluded.last_viewed_at,
                    view_count = media_stats.view_count + 1
                """,
                (media_id, added_at, viewed_at),
            )
            row = cur.execute(
                """
                SELECT media_id, added_at, last_viewed_at, view_count
                  FROM media_stats
                 WHERE media_id = ?
                """,
                (media_id,),
            ).fetchone()
        if row is None:
            raise RuntimeError(f"media_stats row not found after increment: {media_id}")
        return dict(row)

    def upsert_media_activity(
        self,
        media_id: str,
        *,
        viewed_at: str,
        last_page: int | None,
    ) -> dict[str, Any]:
        with self._cursor() as cur:
            cur.execute(
                """
                INSERT INTO media_activity (
                    media_id,
                    last_viewed_at,
                    last_page
                )
                VALUES (?, ?, ?)
                ON CONFLICT(media_id) DO UPDATE SET
                    last_viewed_at = excluded.last_viewed_at,
                    last_page = excluded.last_page
                """,
                (media_id, viewed_at, last_page),
            )
            row = cur.execute(
                """
                SELECT media_id, last_viewed_at, last_page
                  FROM media_activity
                 WHERE media_id = ?
                """,
                (media_id,),
            ).fetchone()
        if row is None:
            raise RuntimeError(
                f"media_activity row not found after upsert: {media_id}"
            )
        return dict(row)

    def list_media_activity(self, *, limit: int = 24) -> list[dict[str, Any]]:
        normalized_limit = max(1, int(limit))
        with self._cursor() as cur:
            rows = cur.execute(
                """
                SELECT
                    activity.media_id,
                    activity.last_viewed_at,
                    activity.last_page,
                    records.folder_raw
                  FROM media_activity AS activity
                  JOIN media_records AS records
                    ON records.media_id = activity.media_id
                 WHERE records.is_deleted = 0
              ORDER BY activity.last_viewed_at DESC
                 LIMIT ?
                """,
                (normalized_limit,),
            ).fetchall()
        return [dict(row) for row in rows]

    def get_reading_progress(self, media_id: str) -> dict[str, Any] | None:
        with self._cursor() as cur:
            row = cur.execute(
                """
                SELECT
                    media_id,
                    current_page,
                    total_pages,
                    progress,
                    last_read_at,
                    updated_at
                  FROM reading_progress
                 WHERE media_id = ?
                """,
                (media_id,),
            ).fetchone()
        return dict(row) if row else None

    def upsert_reading_progress(
        self,
        media_id: str,
        *,
        current_page: int,
        total_pages: int | None,
        progress: float,
        last_read_at: str,
        updated_at: str,
    ) -> dict[str, Any]:
        with self._cursor() as cur:
            cur.execute(
                """
                INSERT INTO reading_progress (
                    media_id,
                    current_page,
                    total_pages,
                    progress,
                    last_read_at,
                    updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(media_id) DO UPDATE SET
                    current_page = excluded.current_page,
                    total_pages = excluded.total_pages,
                    progress = excluded.progress,
                    last_read_at = excluded.last_read_at,
                    updated_at = excluded.updated_at
                """,
                (
                    media_id,
                    current_page,
                    total_pages,
                    progress,
                    last_read_at,
                    updated_at,
                ),
            )
            row = cur.execute(
                """
                SELECT
                    media_id,
                    current_page,
                    total_pages,
                    progress,
                    last_read_at,
                    updated_at
                  FROM reading_progress
                 WHERE media_id = ?
                """,
                (media_id,),
            ).fetchone()
        if row is None:
            raise RuntimeError(
                f"reading_progress row not found after upsert: {media_id}"
            )
        return dict(row)

    def list_reading_progress(self, *, limit: int = 24) -> list[dict[str, Any]]:
        normalized_limit = max(1, int(limit))
        with self._cursor() as cur:
            rows = cur.execute(
                """
                SELECT
                    progress.media_id,
                    progress.current_page,
                    progress.total_pages,
                    progress.progress,
                    progress.last_read_at,
                    progress.updated_at,
                    records.folder_raw,
                    records.display_name
                  FROM reading_progress AS progress
                  JOIN media_records AS records
                    ON records.media_id = progress.media_id
                 WHERE records.is_deleted = 0
                   AND records.kind = 'pdf'
              ORDER BY progress.last_read_at DESC, progress.updated_at DESC
                 LIMIT ?
                """,
                (normalized_limit,),
            ).fetchall()
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

    def list_media_ids_for_tag(self, tag_id: str) -> list[str]:
        with self._cursor() as cur:
            rows = cur.execute(
                """
                SELECT media_id
                  FROM media_tag_links
                 WHERE tag_id = ?
              ORDER BY media_id COLLATE NOCASE
                """,
                (tag_id,),
            ).fetchall()
        return [str(row["media_id"]) for row in rows]

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

    def list_favorite_media_ids(self) -> list[str]:
        with self._cursor() as cur:
            rows = cur.execute(
                """
                SELECT media_id
                  FROM media_favorites
              ORDER BY updated_at DESC, media_id COLLATE NOCASE
                """
            ).fetchall()
        return [str(row["media_id"]) for row in rows]

    def list_favorite_media_records(self) -> list[dict[str, Any]]:
        with self._cursor() as cur:
            rows = cur.execute(
                """
                SELECT records.*
                  FROM media_favorites AS favorites
                  JOIN media_records AS records
                    ON records.media_id = favorites.media_id
                 WHERE records.is_deleted = 0
              ORDER BY favorites.updated_at DESC,
                       records.display_name COLLATE NOCASE
                """
            ).fetchall()
        return [dict(row) for row in rows]

    def set_media_favorite(self, media_id: str, is_favorite: bool, updated_at: str) -> None:
        with self._cursor() as cur:
            if is_favorite:
                cur.execute(
                    """
                    INSERT INTO media_favorites (media_id, updated_at)
                    VALUES (?, ?)
                    ON CONFLICT(media_id) DO UPDATE SET
                        updated_at = excluded.updated_at
                    """,
                    (media_id, updated_at),
                )
            else:
                cur.execute(
                    "DELETE FROM media_favorites WHERE media_id = ?",
                    (media_id,),
                )

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

            stats_row = cur.execute(
                """
                SELECT added_at, last_viewed_at, view_count
                  FROM media_stats
                 WHERE media_id = ?
                """,
                (old_media_id,),
            ).fetchone()
            if stats_row is not None:
                cur.execute(
                    """
                    INSERT INTO media_stats (
                        media_id,
                        added_at,
                        last_viewed_at,
                        view_count
                    )
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(media_id) DO UPDATE SET
                        added_at = CASE
                            WHEN media_stats.added_at <= excluded.added_at THEN media_stats.added_at
                            ELSE excluded.added_at
                        END,
                        last_viewed_at = CASE
                            WHEN media_stats.last_viewed_at IS NULL THEN excluded.last_viewed_at
                            WHEN excluded.last_viewed_at IS NULL THEN media_stats.last_viewed_at
                            WHEN media_stats.last_viewed_at >= excluded.last_viewed_at THEN media_stats.last_viewed_at
                            ELSE excluded.last_viewed_at
                        END,
                        view_count = CASE
                            WHEN media_stats.view_count >= excluded.view_count THEN media_stats.view_count
                            ELSE excluded.view_count
                        END
                    """,
                    (
                        new_media_id,
                        stats_row["added_at"],
                        stats_row["last_viewed_at"],
                        stats_row["view_count"],
                    ),
                )
                cur.execute(
                    "DELETE FROM media_stats WHERE media_id = ?",
                    (old_media_id,),
                )

            progress_row = cur.execute(
                """
                SELECT
                    current_page,
                    total_pages,
                    progress,
                    last_read_at,
                    updated_at
                  FROM reading_progress
                 WHERE media_id = ?
                """,
                (old_media_id,),
            ).fetchone()
            if progress_row is not None:
                cur.execute(
                    """
                    INSERT INTO reading_progress (
                        media_id,
                        current_page,
                        total_pages,
                        progress,
                        last_read_at,
                        updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(media_id) DO UPDATE SET
                        current_page = CASE
                            WHEN reading_progress.updated_at IS NULL THEN excluded.current_page
                            WHEN excluded.updated_at IS NULL THEN reading_progress.current_page
                            WHEN reading_progress.updated_at >= excluded.updated_at THEN reading_progress.current_page
                            ELSE excluded.current_page
                        END,
                        total_pages = CASE
                            WHEN reading_progress.total_pages IS NULL OR reading_progress.total_pages <= 0 THEN excluded.total_pages
                            WHEN excluded.total_pages IS NULL OR excluded.total_pages <= 0 THEN reading_progress.total_pages
                            WHEN reading_progress.updated_at IS NULL THEN excluded.total_pages
                            WHEN excluded.updated_at IS NULL THEN reading_progress.total_pages
                            WHEN reading_progress.updated_at >= excluded.updated_at THEN reading_progress.total_pages
                            ELSE excluded.total_pages
                        END,
                        progress = CASE
                            WHEN reading_progress.updated_at IS NULL THEN excluded.progress
                            WHEN excluded.updated_at IS NULL THEN reading_progress.progress
                            WHEN reading_progress.updated_at >= excluded.updated_at THEN reading_progress.progress
                            ELSE excluded.progress
                        END,
                        last_read_at = CASE
                            WHEN reading_progress.last_read_at IS NULL THEN excluded.last_read_at
                            WHEN excluded.last_read_at IS NULL THEN reading_progress.last_read_at
                            WHEN reading_progress.last_read_at >= excluded.last_read_at THEN reading_progress.last_read_at
                            ELSE excluded.last_read_at
                        END,
                        updated_at = CASE
                            WHEN reading_progress.updated_at IS NULL THEN excluded.updated_at
                            WHEN excluded.updated_at IS NULL THEN reading_progress.updated_at
                            WHEN reading_progress.updated_at >= excluded.updated_at THEN reading_progress.updated_at
                            ELSE excluded.updated_at
                        END
                    """,
                    (
                        new_media_id,
                        progress_row["current_page"],
                        progress_row["total_pages"],
                        progress_row["progress"],
                        progress_row["last_read_at"],
                        progress_row["updated_at"],
                    ),
                )
                cur.execute(
                    "DELETE FROM reading_progress WHERE media_id = ?",
                    (old_media_id,),
                )

            cur.execute(
                "DELETE FROM media_tag_links WHERE media_id = ?",
                (old_media_id,),
            )


