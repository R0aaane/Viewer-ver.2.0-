"""Opt-in migration verification of a read-only copy of an existing host DB."""
from contextlib import closing
import os
from pathlib import Path
import sqlite3
from tempfile import TemporaryDirectory
import unittest

from server.repositories.sqlite_store import SqliteStore


@unittest.skipUnless(os.getenv("MEDIA_SERVER_TEST_DB_COPY"), "Set an existing metadata DB for read-only copy verification")
class ExistingDatabaseMigrationTests(unittest.TestCase):
    def test_copy_preserves_records_tags_and_favorites(self):
        source = Path(os.environ["MEDIA_SERVER_TEST_DB_COPY"]).resolve()
        with TemporaryDirectory() as temporary:
            destination = Path(temporary) / "migration.sqlite"
            with closing(sqlite3.connect(source.as_uri() + "?mode=ro", uri=True)) as original, \
                    closing(sqlite3.connect(destination)) as copied:
                original.backup(copied)
                tables = {row[0] for row in original.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                before = {table: original.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
                          for table in ("media_records", "tag_master", "media_tag_links", "media_favorites") if table in tables}
            self.assertIn("media_records", before)
            store = SqliteStore(destination)
            try:
                store.init_schema()
                store.init_schema()
            finally:
                store.close()
            with closing(sqlite3.connect(destination)) as db:
                self.assertEqual(db.execute("PRAGMA integrity_check").fetchone()[0], "ok")
                for table, count in before.items():
                    self.assertEqual(db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0], count)
