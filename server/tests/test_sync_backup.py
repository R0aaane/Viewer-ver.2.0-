from contextlib import closing
from dataclasses import replace
import errno
import json
import os
from pathlib import Path
import sqlite3
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

from PIL import Image

from server.api.routes_generated import ImageEdit, edit_image, favorite, GalleryQuery
from server.core.config import load_settings
from server.repositories.sqlite_store import SqliteStore
from server.services import change_log, generated_catalog
from server.services.device_tokens import DeviceTokens
from server.services.generated_library import GeneratedLibrary
from server.services.generation_jobs import GenerationJobs
from server.services.host_backup import create_backup, restore_backup, repair_host
from server.services.maintenance import host_lock
from server.services.media_index_service import MediaIndexService


class SyncBackupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.media = self.root / "media"
        self.media.mkdir()
        self.output = self.root / "output"
        self.output.mkdir()
        self.image = self.media / "local.png"
        Image.new("RGB", (20, 30), "blue").save(self.image)
        self.settings = replace(load_settings(), data_dir=self.root / "data",
            sqlite_path=self.root / "data" / "metadata.sqlite", thumbs_dir=self.root / "thumbs",
            media_roots=[str(self.media)], generated_library_dir=self.root / "generated",
            comfy_output_dir=self.output, auth_token="never-back-up-this-host-secret",
            xviewer_saved_images_dir=self.root / "saved-images",
            comfy_presets_path=self.root / "presets.json")
        self.settings.comfy_presets_path.write_text(json.dumps([{"id": "fixture", "parameters": {},
            "workflow": {"1": {"class_type": "TestNode", "inputs": {"api_key": "fixture-secret"}}}}]), encoding="utf-8")
        self.library = GeneratedLibrary(self.output, self.settings.generated_library_dir)
        self.digest = self.library.import_download(self.image)
        store = SqliteStore(self.settings.sqlite_path)
        try:
            store.init_schema()
            MediaIndexService(store).scan_folder(str(self.media))
        finally:
            store.close()

    def test_delta_paging_versions_conflicts_delete_and_restore(self):
        with closing(self.library.connect()) as db:
            page = change_log.changes(db, 0, None, 1)
        first_version = page["items"][0]["version"]
        rename = edit_image(self.digest, ImageEdit(expected_version=first_version, name="manual name"), self.library)
        with self.assertRaises(Exception) as raised:
            favorite(self.digest, True, first_version, self.library)
        self.assertEqual(raised.exception.status_code, 409)
        favorite(self.digest, True, rename["version"], self.library)
        with closing(self.library.connect()) as db:
            current = generated_catalog.detail(db, self.digest)
        deleted = edit_image(self.digest, ImageEdit(expected_version=current["version"], deleted=True), self.library)
        with closing(self.library.connect()) as db:
            self.assertEqual(generated_catalog.search(db, GalleryQuery())["items"], [])
            self.assertEqual(len(generated_catalog.search(db, GalleryQuery(deleted=True))["items"]), 1)
        edit_image(self.digest, ImageEdit(expected_version=deleted["version"], deleted=False), self.library)
        with closing(self.library.connect()) as db:
            generated_catalog.analyze(db, self.digest, self.library.media_path(self.digest, False))
            self.assertEqual(generated_catalog.detail(db, self.digest)["name"], "manual name")
        kinds = []
        cursor = page["cursor"]
        while True:
            with closing(self.library.connect()) as db:
                batch = change_log.changes(db, cursor, page["epoch"], 1)
            kinds.extend(item["kind"] for item in batch["items"])
            cursor = batch["cursor"]
            if not batch["hasMore"]:
                break
        self.assertEqual(kinds, ["rename", "favorite", "delete", "restore"])
        with closing(self.library.connect()) as db:
            self.assertTrue(change_log.changes(db, cursor, "old-backup-epoch", 100)["resetRequired"])

    def test_authenticated_http_delta_and_restore_epoch_guard(self):
        from fastapi import FastAPI
        from types import SimpleNamespace
        import requests
        from server.api.routes_generated import router
        from server.tests.test_routes_generated import serve
        app = FastAPI()
        app.state.settings = SimpleNamespace(auth_token="fixture")
        app.state.generated_library = self.library
        app.include_router(router)
        auth = {"Authorization": "Bearer fixture"}
        with serve(app) as port:
            url = f"http://127.0.0.1:{port}/generated"
            observed = requests.get(url + f"/media/{self.digest}/details", headers=auth, timeout=3).json()
            mutation = {"expected_version": observed["version"], "name": "http-name"}
            self.assertEqual(requests.patch(url + f"/media/{self.digest}",
                headers={**auth, "X-Sync-Epoch": "old-backup"}, json=mutation, timeout=3).status_code, 409)
            self.assertEqual(requests.patch(url + f"/media/{self.digest}",
                headers={**auth, "X-Sync-Epoch": observed["epoch"]}, json=mutation, timeout=3).status_code, 200)
            page = requests.get(url + "/changes?after=0&limit=1", headers=auth, timeout=3).json()
            self.assertTrue(page["hasMore"])
            self.assertEqual(page["epoch"], observed["epoch"])

    def test_legacy_copy_migration_keeps_existing_records(self):
        copy = self.root / "migration-copy.sqlite"
        with closing(sqlite3.connect(self.settings.sqlite_path)) as src, closing(sqlite3.connect(copy)) as dst:
            src.backup(dst)
        with closing(sqlite3.connect(copy)) as db, db:
            for row in db.execute("SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'sync_%'").fetchall():
                db.execute(f'DROP TRIGGER "{row[0]}"')
            for table in ("sync_changes", "entity_versions", "sync_meta"):
                db.execute(f"DROP TABLE {table}")
            count = db.execute("SELECT COUNT(*) FROM media_records").fetchone()[0]
        store = SqliteStore(copy)
        try:
            store.init_schema()
            store.init_schema()
            with closing(sqlite3.connect(copy)) as db:
                self.assertEqual(db.execute("SELECT COUNT(*) FROM media_records").fetchone()[0], count)
                self.assertEqual(db.execute("SELECT COUNT(*) FROM sync_changes").fetchone()[0], count)
        finally:
            store.close()

    def test_legacy_tag_compare_and_swap_rolls_back_all_nested_changes(self):
        from types import SimpleNamespace
        from server.services.metadata_store import MetadataStore
        from server.api.routes_tags import get_tags_for_item, add_tags_to_item, replace_tags_for_item
        from server.models.dto import AddItemTagsRequest
        from fastapi import HTTPException
        store = SqliteStore(self.settings.sqlite_path)
        try:
            store.init_schema()
            metadata = MetadataStore(store)
            with closing(sqlite3.connect(self.settings.sqlite_path)) as db:
                media_id = db.execute("SELECT media_id FROM media_records").fetchone()[0]
            request = SimpleNamespace(query_params={}, app=SimpleNamespace(state=SimpleNamespace(
                metadata_store=metadata, sqlite_store=store)))
            initial = get_tags_for_item(request, media_id)
            update = add_tags_to_item(request, media_id, AddItemTagsRequest(expectedVersion=initial.version,
                tags=[{"category": "free", "name": "first-device"}]))
            with self.assertRaises(HTTPException) as conflict:
                replace_tags_for_item(request, media_id, AddItemTagsRequest(expectedVersion=initial.version, tags=[]))
            self.assertEqual(conflict.exception.status_code, 409)
            with self.assertRaises(HTTPException) as restored:
                replace_tags_for_item(request, media_id, AddItemTagsRequest(expectedVersion=update.version,
                    expectedEpoch="old-backup", tags=[]))
            self.assertEqual(restored.exception.status_code, 409)
            with self.assertRaises(OSError), store.versioned_edit(media_id, update.version):
                with store._cursor() as cursor:
                    cursor.execute("DELETE FROM media_tag_links WHERE media_id=?", (media_id,))
                raise OSError("temporary write failure")
            self.assertEqual([t.name for t in get_tags_for_item(request, media_id).items], ["first-device"])
            self.assertEqual(store.media_version(media_id), update.version)
        finally:
            store.close()

    def test_recorded_host_paths_are_used_without_persisting_bearer_secrets(self):
        from server.services.host_snapshot_settings import persist_host_settings, load_host_settings
        persist_host_settings(self.settings)
        raw = (self.settings.data_dir / "host_settings.json").read_text(encoding="utf-8")
        self.assertNotIn(self.settings.auth_token, raw)
        restored = load_host_settings(load_settings(), self.settings.data_dir)
        self.assertEqual(restored.media_roots, self.settings.media_roots)
        self.assertEqual(restored.generated_library_dir, self.settings.generated_library_dir)

    @unittest.skipUnless(os.name == "nt", "DPAPI requires the Windows user profile")
    def test_encrypted_backup_restore_and_job_quarantine(self):
        (self.media / "large.bin").write_bytes(b"x" * (1024 * 1024 + 7))
        jobs = GenerationJobs(self.library, "http://127.0.0.1:8188", self.settings.comfy_presets_path)
        self.addCleanup(jobs.http.close)
        job = jobs.create("backup-request", "fixture", {})
        device = DeviceTokens(self.settings.data_dir / "device_tokens.sqlite")
        identifier, token = device.issue("backup-device")
        with closing(self.library.connect()) as db, db:
            db.execute("INSERT INTO manual_tags VALUES(?, 'free', 'manual')", (self.digest,))
        archive = self.root / "archive"
        count = create_backup(self.settings, archive)
        self.assertGreater(count, 3)
        for path in archive.iterdir():
            self.assertNotIn(b"fixture-secret", path.read_bytes())
        restored = self.root / "restored"
        self.assertEqual(restore_backup(archive, restored), count)
        self.assertEqual((restored / "generated" / "originals" / f"{self.digest}.png").read_bytes(), self.image.read_bytes())
        self.assertEqual((restored / "media" / "0" / "large.bin").read_bytes(), (self.media / "large.bin").read_bytes())
        with closing(sqlite3.connect(restored / "generated" / "generated.sqlite")) as db:
            self.assertEqual(db.execute("SELECT name FROM manual_tags").fetchone()[0], "manual")
            self.assertEqual(db.execute("SELECT state FROM generation_jobs WHERE id=?", (job["id"],)).fetchone()[0], "failed")
        self.assertIsNone(DeviceTokens(restored / "data" / "device_tokens.sqlite").verify(token))
        with closing(sqlite3.connect(restored / "data" / "metadata.sqlite")) as db:
            self.assertEqual(Path(db.execute("SELECT full_path FROM media_records").fetchone()[0]), restored / "media" / "0" / "local.png")
        safe = json.loads((restored / "restored_settings.json").read_text(encoding="utf-8"))
        self.assertNotIn("MEDIA_SERVER_AUTH_TOKEN", safe)
        self.assertEqual(safe["MEDIA_SERVER_HOST"], "127.0.0.1")
        with self.assertRaises(ValueError):
            restore_backup(archive, restored)

    def test_host_lifetime_lock_prevents_offline_backup(self):
        with host_lock(self.settings.data_dir), host_lock(self.settings.data_dir):
            with self.assertRaises(sqlite3.OperationalError):
                create_backup(self.settings, self.root / "running-backup")
        self.assertFalse((self.root / "running-backup").exists())

    @unittest.skipUnless(os.name == "nt", "DPAPI requires the Windows user profile")
    def test_disk_full_and_corrupt_archive_never_publish(self):
        archive = self.root / "archive"
        with patch("server.services.host_backup.protect", side_effect=OSError(errno.ENOSPC, "disk full")):
            with self.assertRaises(OSError):
                create_backup(self.settings, archive)
        self.assertFalse(archive.exists())
        create_backup(self.settings, archive)
        (archive / "00000000.protected").write_bytes(b"truncated")
        destination = self.root / "bad-restore"
        with self.assertRaises((ValueError, OSError)):
            restore_backup(archive, destination)
        self.assertFalse(destination.exists())
        self.assertEqual(self.image.read_bytes(), self.library.media_path(self.digest, False).read_bytes())

    def test_repair_rebuilds_thumbnail_and_keeps_manual_tags(self):
        thumbnail = self.library.media_path(self.digest, True)
        thumbnail.unlink()
        with closing(self.library.connect()) as db, db:
            db.execute("INSERT INTO manual_tags VALUES(?, 'free', 'keep')", (self.digest,))
        self.assertEqual(repair_host(self.settings), 1)
        self.assertTrue(thumbnail.is_file())
        with closing(self.library.connect()) as db:
            self.assertEqual(db.execute("SELECT name FROM manual_tags").fetchone()[0], "keep")
