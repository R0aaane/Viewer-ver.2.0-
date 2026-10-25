from contextlib import closing
import hashlib
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

import pypdfium2 as pdfium
from fastapi import FastAPI
from fastapi.testclient import TestClient
from pydantic import ValidationError

from server.core.errors import ApiError
from server.api.routes_media import router
from server.models.dto import EditPdfRequest
from server.repositories.sqlite_store import SqliteStore
from server.services.media_index_service import MediaIndexService
from server.services.metadata_store import MetadataStore
from server.services.pdf_edit_service import PdfEditService
from server.services.thumbnail_service import ThumbnailService


class PdfEditTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.library = self.root / 'library'
        self.library.mkdir()
        self.path = self.library / '作品.pdf'
        with closing(pdfium.PdfDocument.new()) as pdf:
            for width in (200, 300, 400):
                pdf.new_page(width, 500).close()
            pdf.save(self.path)
        self.original = self.path.read_bytes()
        self.db = SqliteStore(self.root / 'data/metadata.db')
        self.db.init_schema()
        self.index = MediaIndexService(self.db)
        self.index.index_files([str(self.path)])
        self.mid = self.db.get_media_record_by_path(str(self.path))['media_id']
        self.metadata = MetadataStore(self.db)
        self.thumbnails = ThumbnailService(self.metadata, self.root / 'thumbs')
        self.service = PdfEditService(self.metadata, self.index, self.thumbnails, SimpleNamespace(data_dir=self.root / 'data', media_roots=[str(self.library)]))
        self.revision = hashlib.sha256(self.original).hexdigest()

    def tearDown(self):
        self.thumbnails.close()
        self.db.close()
        self.temporary.cleanup()

    def test_delete_rotate_reorder_preserves_identity_and_supports_restore(self):
        self.metadata.add_tags_to_media(self.mid, [{'category': 'general', 'name': '編集前のタグ'}])
        original_tags = self.metadata.get_tags_for_media(self.mid)
        self.metadata.set_media_rating(self.mid, 5)
        self.metadata.set_media_favorite(self.mid, True)
        self.metadata.upsert_reading_progress(self.mid, current_page=3, total_pages=3, is_bookmarked=True)
        self.thumbnails.get_pdf_page_count(self.mid)  # Hold the original open in the rendering cache.
        result = self.service.edit(self.mid, self.revision, [{'page': 3, 'rotation': 90}, {'page': 1, 'rotation': 0}])
        self.assertEqual(result['pageCount'], 2)
        self.assertNotEqual(result['revision'], self.revision)
        with closing(pdfium.PdfDocument(self.path)) as pdf:
            self.assertEqual(len(pdf), 2)
            with closing(pdf.get_page(0)) as page:
                self.assertEqual(page.get_rotation(), 90)
                self.assertEqual(page.get_size(), (500, 400))
            with closing(pdf.get_page(1)) as page:
                self.assertEqual(page.get_size(), (200, 500))
        self.assertEqual(self.db.get_media_record_by_path(str(self.path))['media_id'], self.mid)
        self.assertEqual(self.metadata.list_media_ratings()[self.mid], 5)
        self.assertIn(self.mid, self.metadata.list_favorite_media_ids())
        self.assertEqual(self.metadata.get_tags_for_media(self.mid), original_tags)
        progress = self.metadata.get_reading_progress(self.mid)
        self.assertEqual((progress['currentPage'], progress['totalPages']), (1, 2))
        self.assertTrue(progress['isBookmarked'])
        self.assertEqual(self.thumbnails.get_pdf_page_count(self.mid), 2)
        info = self.service.info(self.mid)
        self.assertEqual(info['backups'][0]['id'], result['backupId'])
        restored = self.service.restore(self.mid, result['revision'], result['backupId'])
        self.assertEqual(restored['pageCount'], 3)
        self.assertEqual(self.path.read_bytes(), self.original)
        self.assertEqual(self.metadata.get_tags_for_media(self.mid), original_tags)
        self.assertEqual(len(self.service.info(self.mid)['backups']), 2)

    def test_invalid_edits_and_stale_revision_never_change_original(self):
        for pages in ([], [{'page': 0, 'rotation': 0}], [{'page': 4, 'rotation': 0}], [{'page': 1, 'rotation': 0}, {'page': 1, 'rotation': 0}], [{'page': 1, 'rotation': 45}], [{'page': True, 'rotation': 0}]):
            with self.subTest(pages=pages), self.assertRaises(ApiError):
                self.service.edit(self.mid, self.revision, pages)
            self.assertEqual(self.path.read_bytes(), self.original)
        with self.assertRaises(ApiError) as error:
            self.service.edit(self.mid, '0' * 64, [{'page': 1, 'rotation': 90}])
        self.assertEqual(error.exception.status_code, 409)
        self.assertEqual(self.path.read_bytes(), self.original)

    def test_noop_is_rejected_without_backups(self):
        with self.assertRaises(ApiError):
            self.service.edit(self.mid, self.revision, [{'page': page, 'rotation': 0} for page in (1, 2, 3)])
        self.assertEqual(self.service.info(self.mid)['backups'], [])

    def test_backup_failure_and_index_failure_preserve_original(self):
        pages = [{'page': 2, 'rotation': 0}]
        with patch('server.services.pdf_edit_service.json.dump', side_effect=OSError('disk full')):
            with self.assertRaises(OSError):
                self.service.edit(self.mid, self.revision, pages)
        self.assertEqual(self.path.read_bytes(), self.original)
        index_files = self.index.index_files
        calls = 0

        def fail_once(paths):
            nonlocal calls
            calls += 1
            if calls == 1:
                raise RuntimeError('index failed')
            return index_files(paths)

        with patch.object(self.index, 'index_files', side_effect=fail_once):
            with self.assertRaises(RuntimeError):
                self.service.edit(self.mid, self.revision, pages)
        self.assertEqual(self.path.read_bytes(), self.original)
        self.assertEqual(self.thumbnails.get_pdf_page_count(self.mid), 3)

    def test_restore_rejects_foreign_id_stale_revision_and_corrupt_backup(self):
        result = self.service.edit(self.mid, self.revision, [{'page': 2, 'rotation': 0}])
        edited = self.path.read_bytes()
        for backup_id in ('../original.pdf', 'f' * 32):
            with self.assertRaises(ApiError):
                self.service.restore(self.mid, result['revision'], backup_id)
        with self.assertRaises(ApiError) as error:
            self.service.restore(self.mid, self.revision, result['backupId'])
        self.assertEqual(error.exception.status_code, 409)
        backup = self.service._backup_dir(self.mid) / result['backupId'] / 'original.pdf'
        backup.write_bytes(b'corrupt')
        with self.assertRaises(ApiError):
            self.service.restore(self.mid, result['revision'], result['backupId'])
        self.assertEqual(self.path.read_bytes(), edited)

    def test_files_outside_media_roots_and_corrupt_pdfs_are_rejected(self):
        self.service._roots = [self.root / 'different']
        with self.assertRaises(ApiError) as error:
            self.service.info(self.mid)
        self.assertEqual(error.exception.status_code, 403)
        self.service._roots = [self.library]
        self.path.write_bytes(b'not pdf')
        with self.assertRaises(ApiError):
            self.service.info(self.mid)

    def test_request_rejects_missing_or_non_integer_page_numbers(self):
        for pages in ([], [{'page': '1'}], [{'page': True}], [{'page': 1, 'rotation': 1.5}]):
            with self.assertRaises(ValidationError):
                EditPdfRequest(revision=self.revision, pages=pages)

    def test_authenticated_http_edit_conflict_and_restore(self):
        app = FastAPI()
        app.state.settings = SimpleNamespace(auth_token='test-secret')
        app.state.pdf_edit_service = self.service
        app.include_router(router)
        endpoint = f'/media/{self.mid}/pdf-edit'
        headers = {'Authorization': 'Bearer test-secret'}
        with TestClient(app) as client:
            self.assertEqual(client.get(endpoint).status_code, 401)
            info = client.get(endpoint, headers=headers)
            self.assertEqual(info.status_code, 200)
            self.assertEqual(info.json()['pageCount'], 3)
            malformed = client.post(endpoint, headers=headers, json={'revision': self.revision, 'pages': []})
            self.assertEqual(malformed.status_code, 422)
            payload = {'revision': self.revision, 'pages': [{'page': 2, 'rotation': 90}]}
            edited = client.post(endpoint, headers=headers, json=payload)
            self.assertEqual(edited.status_code, 200)
            self.assertEqual(edited.json()['pageCount'], 1)
            self.assertEqual(client.post(endpoint, headers=headers, json=payload).status_code, 409)
            restored = client.post(endpoint + '/restore', headers=headers, json={
                'revision': edited.json()['revision'], 'backupId': edited.json()['backupId'],
            })
            self.assertEqual(restored.status_code, 200)
            self.assertEqual(self.path.read_bytes(), self.original)
