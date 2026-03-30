import os
import tempfile
import time
import unittest
from pathlib import Path

from server.repositories.sqlite_store import SqliteStore
from server.services.media_index_service import MediaIndexService


class MediaIndexServiceTest(unittest.TestCase):
    def test_scan_folder_reuses_existing_media_id_for_same_path(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            db_path = Path(temp_dir) / 'metadata.db'
            library_dir = Path(temp_dir) / 'library'
            library_dir.mkdir()
            target = library_dir / 'テスト.pdf'
            target.write_bytes(b'first-version')

            store = SqliteStore(db_path)
            try:
                store.init_schema()
                service = MediaIndexService(store)

                scanned_first = service.scan_folder(str(library_dir))
                self.assertEqual(scanned_first, 1)
                first_row = store.get_media_record_by_path(str(target))
                self.assertIsNotNone(first_row)
                first_media_id = str(first_row['media_id'])
                first_modified = int(first_row['modified_epoch_ms'])

                time.sleep(0.02)
                target.write_bytes(b'second-version-with-new-size')
                os.utime(target, None)

                scanned_second = service.scan_folder(str(library_dir))
                self.assertEqual(scanned_second, 1)
                second_row = store.get_media_record_by_path(str(target))
                self.assertIsNotNone(second_row)
                self.assertEqual(str(second_row['media_id']), first_media_id)
                self.assertGreaterEqual(int(second_row['modified_epoch_ms']), first_modified)
            finally:
                store.close()


if __name__ == '__main__':
    unittest.main()

