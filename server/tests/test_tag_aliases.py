import tempfile
import unittest
from pathlib import Path

from server.repositories.sqlite_store import SqliteStore
from server.services.metadata_store import MetadataStore, SearchQuery, build_media_id
from server.services.tag_alias_service import TagAliasService


class TagAliasMetadataStoreTest(unittest.TestCase):
    def setUp(self) -> None:
        self._temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._temp_dir.cleanup)

        self.db_path = Path(self._temp_dir.name) / "metadata.db"
        self.library_dir = Path(self._temp_dir.name) / "library"
        self.library_dir.mkdir()

        self.sqlite = SqliteStore(self.db_path)
        self.addCleanup(self.sqlite.close)
        self.sqlite.init_schema()

        self.alias_service = TagAliasService.from_json_text(
            """
            {
              "series": {
                "東方Project": ["Touhou Project", "Touhou", "東方"]
              },
              "character": {
                "博麗霊夢": ["Hakurei Reimu", "Reimu Hakurei", "霊夢"]
              }
            }
            """
        )

    def _insert_media(self, file_name: str) -> str:
        target = self.library_dir / file_name
        target.write_bytes(b"test")
        media_id = build_media_id(
            kind="image",
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
                "kind": "image",
                "mime_type": "image/jpeg",
                "size_bytes": 4,
                "modified_at": None,
                "modified_epoch_ms": 1,
                "etag": None,
                "is_deleted": 0,
            }
        )
        return media_id

    def test_search_media_matches_alias_query_against_canonical_tag(self) -> None:
        store = MetadataStore(self.sqlite, tag_alias_service=self.alias_service)
        media_id = self._insert_media("sample.jpg")
        store.add_tags_to_media(
            media_id,
            [
                {"category": "series", "name": "東方Project"},
                {"category": "character", "name": "博麗霊夢"},
            ],
        )

        items, total = store.search_media(SearchQuery(series="Touhou Project"))

        self.assertEqual(total, 1)
        self.assertEqual(items[0]["mediaId"], media_id)

        tags = {
            (tag["category"], tag["name"])
            for tag in store.get_tags_for_media(media_id)
        }
        self.assertIn(("series", "東方Project"), tags)
        self.assertIn(("character", "博麗霊夢"), tags)

    def test_list_tag_master_returns_canonical_tag_for_alias_contains(self) -> None:
        store = MetadataStore(self.sqlite, tag_alias_service=self.alias_service)
        media_id = self._insert_media("sample.jpg")
        store.add_tags_to_media(
            media_id,
            [{"category": "series", "name": "東方Project"}],
        )

        tags = store.list_tag_master(category="series", contains="Touhou")

        self.assertEqual(
            [(tag["category"], tag["name"]) for tag in tags],
            [("series", "東方Project")],
        )

    def test_backfill_replaces_existing_alias_master_with_canonical_tag(self) -> None:
        plain_store = MetadataStore(self.sqlite)
        media_id = self._insert_media("sample.jpg")
        plain_store.add_tags_to_media(
            media_id,
            [{"category": "series", "name": "Touhou Project"}],
        )

        store = MetadataStore(self.sqlite, tag_alias_service=self.alias_service)
        result = store.backfill_configured_tag_aliases()

        self.assertEqual(result["removedAliasCount"], 1)
        self.assertEqual(result["migratedLinkCount"], 1)
        self.assertEqual(
            {
                (tag["category"], tag["name"])
                for tag in store.get_tags_for_media(media_id)
            },
            {("series", "東方Project")},
        )
        self.assertEqual(
            {
                (tag["category"], tag["name"])
                for tag in self.sqlite.list_tag_master()
            },
            {("series", "東方Project")},
        )


if __name__ == "__main__":
    unittest.main()
