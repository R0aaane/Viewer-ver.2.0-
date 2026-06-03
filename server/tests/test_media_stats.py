import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from server.repositories.sqlite_store import SqliteStore
from server.services.metadata_store import MetadataStore, SearchQuery, build_media_id


class MediaStatsTest(unittest.TestCase):
    def setUp(self) -> None:
        self._temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._temp_dir.cleanup)

        self.db_path = Path(self._temp_dir.name) / "metadata.db"
        self.library_dir = Path(self._temp_dir.name) / "library"
        self.library_dir.mkdir()

        self.sqlite = SqliteStore(self.db_path)
        self.addCleanup(self.sqlite.close)
        self.sqlite.init_schema()
        self.store = MetadataStore(self.sqlite)

        self.pdf_media_id = self._insert_media("sample.pdf", kind="pdf", mime_type="application/pdf")
        self.image_media_id = self._insert_media("sample.jpg", kind="image", mime_type="image/jpeg")

    def _insert_media(self, file_name: str, *, kind: str, mime_type: str) -> str:
        target = self.library_dir / file_name
        target.write_bytes(b"test")
        media_id = build_media_id(
            kind=kind,
            full_path=str(target),
            folder_raw=str(self.library_dir),
            display_name=file_name,
            size_bytes=4,
            modified_epoch_ms=1,
        )
        self.sqlite.upsert_media_record(
            {
                "media_id": media_id,
                "folder_raw": str(self.library_dir),
                "relative_hint": file_name,
                "display_name": file_name,
                "full_path": str(target),
                "normalized_full_path": str(target).replace("/", "\\").casefold(),
                "kind": kind,
                "mime_type": mime_type,
                "size_bytes": 4,
                "modified_at": None,
                "modified_epoch_ms": 1,
                "etag": None,
                "is_deleted": 0,
            }
        )
        return media_id

    def test_seed_missing_media_stats_initializes_existing_pdfs(self) -> None:
        inserted = self.store.seed_missing_media_stats()

        self.assertEqual(inserted, 1)

        items, total = self.store.search_media(SearchQuery(media_type="pdf"))

        self.assertEqual(total, 1)
        self.assertEqual(items[0]["mediaId"], self.pdf_media_id)
        self.assertIsNotNone(items[0]["stats"])
        self.assertEqual(items[0]["stats"]["viewCount"], 0)
        self.assertIsNotNone(items[0]["stats"]["addedAt"])

        image_stats = self.sqlite.get_media_stats(self.image_media_id)
        self.assertIsNone(image_stats)

    def test_record_media_view_updates_host_side_stats(self) -> None:
        self.store.seed_missing_media_stats()

        first = self.store.record_media_view(self.pdf_media_id)
        second = self.store.record_media_view(self.pdf_media_id)

        self.assertEqual(first["viewCount"], 1)
        self.assertIsNotNone(first["lastViewedAt"])
        self.assertEqual(second["viewCount"], 2)
        self.assertIsNotNone(second["lastViewedAt"])


    def test_record_media_view_rejects_non_pdf_media(self) -> None:
        self.store.seed_missing_media_stats()

        with self.assertRaises(Exception):
            self.store.record_media_view(self.image_media_id)

    def test_record_media_activity_persists_resume_page_and_recent_order(self) -> None:
        first = self.store.record_media_activity(
            self.pdf_media_id,
            last_page=7,
            total_pages=20,
        )
        second = self.store.record_media_activity(self.image_media_id)

        recent = self.store.list_recent_media_activity(limit=10)

        self.assertEqual(first["mediaId"], self.pdf_media_id)
        self.assertEqual(first["lastPage"], 7)
        self.assertEqual(second["mediaId"], self.image_media_id)
        self.assertIsNone(second["lastPage"])
        self.assertEqual(
            [entry["mediaId"] for entry in recent[:2]],
            [self.image_media_id, self.pdf_media_id],
        )

    def test_upsert_reading_progress_clamps_page_and_progress(self) -> None:
        entry = self.store.upsert_reading_progress(
            self.pdf_media_id,
            current_page=99,
            total_pages=12,
            progress=0.1,
            last_read_at=datetime(2026, 1, 2, tzinfo=timezone.utc),
            updated_at=datetime(2026, 1, 2, tzinfo=timezone.utc),
        )

        self.assertEqual(entry["currentPage"], 12)
        self.assertEqual(entry["totalPages"], 12)
        self.assertEqual(entry["progress"], 1.0)

    def test_upsert_reading_progress_prefers_newer_updated_at(self) -> None:
        newer = datetime(2026, 1, 3, tzinfo=timezone.utc)
        older = newer - timedelta(minutes=5)

        first = self.store.upsert_reading_progress(
            self.pdf_media_id,
            current_page=15,
            total_pages=40,
            progress=0.375,
            last_read_at=newer,
            updated_at=newer,
        )
        second = self.store.upsert_reading_progress(
            self.pdf_media_id,
            current_page=3,
            total_pages=10,
            progress=0.3,
            last_read_at=older,
            updated_at=older,
        )

        self.assertEqual(first["currentPage"], 15)
        self.assertEqual(second["currentPage"], 15)
        self.assertEqual(second["totalPages"], 40)
        self.assertEqual(second["updatedAt"], newer)

    def test_upsert_reading_progress_preserves_bookmark_when_omitted(self) -> None:
        timestamp = datetime(2026, 1, 4, tzinfo=timezone.utc)
        first = self.store.upsert_reading_progress(
            self.pdf_media_id,
            current_page=4,
            total_pages=20,
            last_read_at=timestamp,
            updated_at=timestamp,
            is_bookmarked=True,
        )
        second = self.store.upsert_reading_progress(
            self.pdf_media_id,
            current_page=5,
            total_pages=20,
            last_read_at=timestamp + timedelta(minutes=1),
            updated_at=timestamp + timedelta(minutes=1),
        )

        self.assertTrue(first["isBookmarked"])
        self.assertTrue(second["isBookmarked"])

    def test_list_recent_reading_progress_returns_home_card_fields(self) -> None:
        timestamp = datetime(2026, 1, 4, tzinfo=timezone.utc)
        self.store.upsert_reading_progress(
            self.pdf_media_id,
            current_page=8,
            total_pages=16,
            progress=0.5,
            last_read_at=timestamp,
            updated_at=timestamp,
        )

        recent = self.store.list_recent_reading_progress(limit=10)

        self.assertEqual(len(recent), 1)
        self.assertEqual(recent[0]["mediaId"], self.pdf_media_id)
        self.assertEqual(recent[0]["title"], "sample.pdf")
        self.assertEqual(recent[0]["currentPage"], 8)
        self.assertEqual(recent[0]["totalPages"], 16)
        self.assertEqual(recent[0]["progress"], 0.5)
        self.assertEqual(recent[0]["lastReadAt"], timestamp)
        self.assertEqual(recent[0]["updatedAt"], timestamp)
        self.assertTrue(str(recent[0]["thumbnailUrl"]).endswith("/thumb"))


if __name__ == "__main__":
    unittest.main()
