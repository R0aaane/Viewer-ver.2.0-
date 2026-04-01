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

    def test_delete_tag_master_removes_links_from_all_media(self) -> None:
        self.store.add_tags_to_media(
            self.media_id_1,
            [{'category': 'artist', 'name': 'Artist A'}],
        )
        self.store.add_tags_to_media(
            self.media_id_2,
            [{'category': 'artist', 'name': 'Artist A'}],
        )
        tag_id = self.sqlite.list_tag_master()[0]['tag_id']

        deleted = self.store.delete_tag_master(str(tag_id))

        self.assertEqual(deleted, 1)
        self.assertEqual(self._master_tags(), set())
        self.assertEqual(self._media_tags(self.media_id_1), set())
        self.assertEqual(self._media_tags(self.media_id_2), set())

    def test_apply_delete_removes_folder_and_marks_descendants_deleted(self) -> None:
        folder = self.library_dir / 'artist-folder'
        folder.mkdir()
        nested = folder / 'nested.jpg'
        nested.write_bytes(b'test')
        media_id = build_media_id(
            kind='image',
            full_path=str(nested),
            folder_raw=str(folder),
            display_name='nested.jpg',
            size_bytes=4,
            modified_epoch_ms=1,
        )
        self.sqlite.upsert_media_record(
            {
                'media_id': media_id,
                'folder_raw': str(folder),
                'relative_hint': 'nested.jpg',
                'display_name': 'nested.jpg',
                'full_path': str(nested),
                'normalized_full_path': str(nested).replace('/', '\\').casefold(),
                'kind': 'image',
                'mime_type': 'image/jpeg',
                'size_bytes': 4,
                'modified_at': None,
                'modified_epoch_ms': 1,
                'etag': None,
                'is_deleted': 0,
            }
        )

        deleted = self.store.apply_delete(
            [{'path': str(folder)}],
            hard_delete=True,
        )

        self.assertEqual(deleted, 1)
        self.assertFalse(folder.exists())
        record = self.sqlite.get_media_record(media_id)
        self.assertIsNotNone(record)
        self.assertEqual(record['is_deleted'], 1)

    def test_apply_delete_removes_empty_folder_without_indexed_descendants(self) -> None:
        folder = self.library_dir / 'empty-folder'
        folder.mkdir()

        deleted = self.store.apply_delete(
            [{'path': str(folder)}],
            hard_delete=True,
        )

        self.assertEqual(deleted, 1)
        self.assertFalse(folder.exists())

    def test_apply_rename_renames_folder_and_updates_descendant_records(self) -> None:
        folder = self.library_dir / 'artist-folder'
        folder.mkdir()
        nested = folder / 'nested.jpg'
        nested.write_bytes(b'test')
        media_id = build_media_id(
            kind='image',
            full_path=str(nested),
            folder_raw=str(folder),
            display_name='nested.jpg',
            size_bytes=4,
            modified_epoch_ms=1,
        )
        self.sqlite.upsert_media_record(
            {
                'media_id': media_id,
                'folder_raw': str(folder),
                'relative_hint': 'nested.jpg',
                'display_name': 'nested.jpg',
                'full_path': str(nested),
                'normalized_full_path': str(nested).replace('/', '\\').casefold(),
                'kind': 'image',
                'mime_type': 'image/jpeg',
                'size_bytes': 4,
                'modified_at': None,
                'modified_epoch_ms': 1,
                'etag': None,
                'is_deleted': 0,
            }
        )

        renamed_folder = self.library_dir / 'artist-folder-renamed'
        result = self.store.apply_rename(
            old_media_id=None,
            new_media_id=None,
            old_path=str(folder),
            new_path=str(renamed_folder),
        )

        self.assertEqual(result['fullPath'], str(renamed_folder))
        self.assertFalse(folder.exists())
        self.assertTrue(renamed_folder.exists())
        self.assertIsNone(self.sqlite.get_media_record(media_id))
        updated = self.sqlite.get_media_record_by_path(str(renamed_folder / 'nested.jpg'))
        self.assertIsNotNone(updated)
        self.assertEqual(updated['folder_raw'], str(renamed_folder))

    def test_organize_media_by_tags_skips_duplicate_target_without_suffix_copy(self) -> None:
        source = self.library_dir / 'sample.pdf'
        source.write_bytes(b'source')
        source_media_id = build_media_id(
            kind='pdf',
            full_path=str(source),
            folder_raw=str(self.library_dir),
            display_name='sample.pdf',
            size_bytes=6,
            modified_epoch_ms=1,
        )
        self.sqlite.upsert_media_record(
            {
                'media_id': source_media_id,
                'folder_raw': str(self.library_dir),
                'relative_hint': 'sample.pdf',
                'display_name': 'sample.pdf',
                'full_path': str(source),
                'normalized_full_path': str(source).replace('/', '\\').casefold(),
                'kind': 'pdf',
                'mime_type': 'application/pdf',
                'size_bytes': 6,
                'modified_at': None,
                'modified_epoch_ms': 1,
                'etag': None,
                'is_deleted': 0,
            }
        )
        self.store.add_tags_to_media(
            source_media_id,
            [{'category': 'artist', 'name': 'Conflict Artist'}],
        )

        conflict_dir = self.library_dir / '作者別' / 'Conflict Artist'
        conflict_dir.mkdir(parents=True)
        conflict_path = conflict_dir / 'sample.pdf'
        conflict_path.write_bytes(b'other')

        moved = self.store.organize_media_by_tags(
            library_root=str(self.library_dir),
            media_ids=[source_media_id],
        )

        self.assertEqual(moved, {})
        self.assertTrue(source.exists())
        self.assertTrue(conflict_path.exists())
        self.assertFalse((conflict_dir / 'sample (1).pdf').exists())
        record = self.sqlite.get_media_record(source_media_id)
        self.assertIsNotNone(record)
        self.assertEqual(record['full_path'], str(source))

if __name__ == '__main__':
    unittest.main()




