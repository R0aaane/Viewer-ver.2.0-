import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from server.repositories.sqlite_store import SqliteStore
from server.services.metadata_store import MetadataStore


class RenameLockTest(unittest.TestCase):
    def test_apply_rename_retries_a_locked_file(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source = root / "locked.pdf"
            target = root / "renamed.pdf"
            source.write_bytes(b"%PDF-1.4")
            store = MetadataStore(SqliteStore(root / "metadata.db"))
            store._db.init_schema()
            original_replace = os.replace
            attempts = 0

            def replace_after_one_lock(old_path: str, new_path: str) -> None:
                nonlocal attempts
                attempts += 1
                if attempts == 1:
                    raise PermissionError(13, "file is in use")
                original_replace(old_path, new_path)

            with (
                patch(
                    "server.services.metadata_store.os.replace",
                    replace_after_one_lock,
                ),
                patch("server.services.metadata_store.time.sleep") as sleep,
            ):
                store.apply_rename(
                    old_media_id=None,
                    new_media_id=None,
                    old_path=str(source),
                    new_path=str(target),
                )

            self.assertEqual(attempts, 2)
            sleep.assert_called_once_with(0.3)
            self.assertTrue(target.exists())
            store._db.close()


if __name__ == "__main__":
    unittest.main()
