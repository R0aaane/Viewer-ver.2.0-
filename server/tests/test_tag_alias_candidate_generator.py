import json
import tempfile
import unittest
from pathlib import Path

from server.repositories.sqlite_store import SqliteStore
from server.services.tag_alias_candidate_generator import generate_tag_alias_candidates


class TagAliasCandidateGeneratorTest(unittest.TestCase):
    def setUp(self) -> None:
        self._temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._temp_dir.cleanup)

        self.root = Path(self._temp_dir.name)
        self.db_path = self.root / "metadata.db"
        self.config_path = self.root / "tag_aliases.json"

        self.sqlite = SqliteStore(self.db_path)
        self.addCleanup(self.sqlite.close)
        self.sqlite.init_schema()

    def _insert_media(self, media_id: str, file_name: str) -> None:
        target = self.root / file_name
        target.write_bytes(b"test")
        self.sqlite.upsert_media_record(
            {
                "media_id": media_id,
                "folder_raw": str(self.root),
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

    def _insert_tag(self, *, tag_id: str, category: str, name: str, media_ids: list[str]) -> None:
        self.sqlite.insert_tag(
            tag_id,
            name,
            category,
            name.casefold(),
        )
        for media_id in media_ids:
            self.sqlite.add_media_tag_link(media_id, tag_id)

    def test_extends_existing_series_canonical_from_db_signature(self) -> None:
        self.config_path.write_text(
            json.dumps(
                {
                    "series": {
                        "東方Project": ["Touhou"],
                    },
                    "character": {},
                },
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )

        self._insert_media("m1", "sample1.jpg")
        self._insert_media("m2", "sample2.jpg")
        self._insert_tag(
            tag_id="series:touhou",
            category="series",
            name="Touhou",
            media_ids=["m1", "m2"],
        )
        self._insert_tag(
            tag_id="series:touhou_project",
            category="series",
            name="Touhou Project",
            media_ids=["m1", "m2"],
        )

        merged, report = generate_tag_alias_candidates(
            db_path=self.db_path,
            config_path=self.config_path,
        )

        self.assertIn("Touhou Project", merged["series"]["東方Project"])
        applied = [
            entry
            for entry in report["applied"]
            if entry["category"] == "series" and entry["canonical"] == "東方Project"
        ]
        self.assertTrue(applied)

    def test_reports_mixed_script_character_pair_for_review(self) -> None:
        self.config_path.write_text(
            json.dumps(
                {
                    "series": {},
                    "character": {},
                },
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )

        self._insert_media("m1", "sample1.jpg")
        self._insert_media("m2", "sample2.jpg")
        self._insert_tag(
            tag_id="character:jp",
            category="character",
            name="博麗霊夢",
            media_ids=["m1", "m2"],
        )
        self._insert_tag(
            tag_id="character:en",
            category="character",
            name="Hakurei Reimu",
            media_ids=["m1", "m2"],
        )

        merged, report = generate_tag_alias_candidates(
            db_path=self.db_path,
            config_path=self.config_path,
        )

        self.assertEqual(merged["character"], {})
        review = [
            entry
            for entry in report["review"]
            if entry["category"] == "character"
        ]
        self.assertEqual(len(review), 1)
        self.assertEqual(review[0]["canonical"], "博麗霊夢")
        self.assertEqual(review[0]["aliases"], ["Hakurei Reimu"])


if __name__ == "__main__":
    unittest.main()
