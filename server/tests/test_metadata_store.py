import tempfile
import unittest
from pathlib import Path

from server.repositories.sqlite_store import SqliteStore
from server.services.metadata_store import MetadataStore, build_media_id


class MetadataStoreTagSyncTest(unittest.TestCase):
    def setUp(self) -> None:
        self._temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._temp_dir.cleanup)

        self.db_path = Path(self._temp_dir.name) / 'metadata.db'
        self.library_dir = Path(self._temp_dir.name) / 'library'
        self.library_dir.mkdir()

        self.sqlite = SqliteStore(self.db_path)
        self.addCleanup(self.sqlite.close)
        self.sqlite.init_schema()
        self.store = MetadataStore(self.sqlite)

        self.media_id_1 = self._insert_media('sample-1.jpg')
        self.media_id_2 = self._insert_media('sample-2.jpg')

    def _insert_media(self, file_name: str) -> str:
        target = self.library_dir / file_name
        target.write_bytes(b'test')
        media_id = build_media_id(
            kind='image',
            full_path=str(target),
            folder_raw=str(self.library_dir),
            display_name=file_name,
            size_bytes=4,
            modified_epoch_ms=1,
        )
        self.sqlite.upsert_media_record(
            {
                'media_id': media_id,
                'folder_raw': str(self.library_dir),
                'relative_hint': file_name,
                'display_name': file_name,
                'full_path': str(target),
                'normalized_full_path': str(target).replace('/', '\\').casefold(),
                'kind': 'image',
                'mime_type': 'image/jpeg',
                'size_bytes': 4,
                'modified_at': None,
                'modified_epoch_ms': 1,
                'etag': None,
                'is_deleted': 0,
            }
        )
        return media_id

    def _media_tags(self, media_id: str) -> set[tuple[str, str]]:
        return {
            (str(tag['category']), str(tag['name']))
            for tag in self.store.get_tags_for_media(media_id)
        }

    def _master_tags(self) -> set[tuple[str, str]]:
        return {
            (str(tag['category']), str(tag['name']))
            for tag in self.sqlite.list_tag_master()
        }

    def test_creates_new_tag_when_host_has_no_match(self) -> None:
        self.store.add_tags_to_media(
            self.media_id_1,
            [{'category': 'artist', 'name': 'Agua Larson'}],
        )

        self.assertEqual(
            self._media_tags(self.media_id_1),
            {('artist', 'Agua Larson')},
        )
        self.assertEqual(
            self._master_tags(),
            {('artist', 'Agua Larson')},
        )

    def test_does_not_reuse_partial_match(self) -> None:
        self.store.add_tags_to_media(
            self.media_id_1,
            [{'category': 'artist', 'name': 'Aqua'}],
        )

        self.store.add_tags_to_media(
            self.media_id_2,
            [{'category': 'artist', 'name': 'Agua Larson'}],
        )

        self.assertEqual(
            self._media_tags(self.media_id_2),
            {('artist', 'Agua Larson')},
        )
        self.assertEqual(
            self._master_tags(),
            {('artist', 'Aqua'), ('artist', 'Agua Larson')},
        )

    def test_does_not_reuse_same_name_from_different_category(self) -> None:
        self.store.add_tags_to_media(
            self.media_id_1,
            [{'category': 'free', 'name': 'Shared Name'}],
        )

        self.store.add_tags_to_media(
            self.media_id_2,
            [{'category': 'artist', 'name': 'Shared Name'}],
        )

        self.assertEqual(
            self._media_tags(self.media_id_2),
            {('artist', 'Shared Name')},
        )
        self.assertEqual(
            self._master_tags(),
            {('free', 'Shared Name'), ('artist', 'Shared Name')},
        )

    def test_stores_each_category_independently(self) -> None:
        self.store.add_tags_to_media(
            self.media_id_1,
            [
                {'category': 'artist', 'name': 'Agua Larson'},
                {'category': 'series', 'name': 'Summer Line'},
                {'category': 'character', 'name': 'Heroine X'},
                {'category': 'free', 'name': 'bonus'},
            ],
        )

        self.assertEqual(
            self._media_tags(self.media_id_1),
            {
                ('artist', 'Agua Larson'),
                ('series', 'Summer Line'),
                ('character', 'Heroine X'),
                ('free', 'bonus'),
            },
        )

    def test_ignores_blank_tags_after_trim(self) -> None:
        self.store.add_tags_to_media(
            self.media_id_1,
            [
                {'category': 'artist', 'name': '   '},
                {'category': 'free', 'name': ' bonus '},
                {'category': 'character', 'name': ''},
            ],
        )

        self.assertEqual(
            self._media_tags(self.media_id_1),
            {('free', 'bonus')},
        )
        self.assertEqual(
            self._master_tags(),
            {('free', 'bonus')},
        )


if __name__ == '__main__':
    unittest.main()
