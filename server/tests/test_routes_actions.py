import asyncio
import base64
import json
import os
import tempfile
from types import SimpleNamespace
import unittest

from server.api.routes_actions import apply_delete, apply_rename, download_url, organize_library, request_rescan, upload_files
from server.core.errors import ApiError, bad_request
from server.models.dto import (
    DeleteItemRequest,
    DeleteRequest,
    DownloadUrlRequest,
    OrganizeLibraryRequest,
    RenameRequest,
    RenameSideDto,
)
from server.services.url_download_service import UrlDownloadError, UrlDownloadResult


_GIF_1X1 = (
    b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff!"
    b"\xf9\x04\x00\x00\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00"
    b"\x00\x02\x02D\x01\x00;"
)


class _RecordingMetadataStore:
    def __init__(
        self,
        *,
        rename_error: Exception | None = None,
        delete_error: Exception | None = None,
        organize_error: Exception | None = None,
        deleted_count: int = 1,
        organize_result: dict[str, str] | None = None,
    ) -> None:
        self.rename_error = rename_error
        self.delete_error = delete_error
        self.organize_error = organize_error
        self.deleted_count = deleted_count
        self.organize_result = organize_result or {}
        self.rename_calls: list[dict[str, object | None]] = []
        self.delete_calls: list[dict[str, object]] = []
        self.organize_calls: list[dict[str, object | None]] = []
        self.backfill_calls = 0

    def apply_rename(
        self,
        *,
        old_media_id: str | None,
        new_media_id: str | None,
        old_path: str | None,
        new_path: str | None,
    ) -> dict[str, str]:
        self.rename_calls.append(
            {
                'old_media_id': old_media_id,
                'new_media_id': new_media_id,
                'old_path': old_path,
                'new_path': new_path,
            }
        )
        if self.rename_error is not None:
            raise self.rename_error
        return {'message': 'ok'}

    def apply_delete(self, items: list[dict[str, object]], hard_delete: bool = False) -> int:
        self.delete_calls.append(
            {
                'items': items,
                'hard_delete': hard_delete,
            }
        )
        if self.delete_error is not None:
            raise self.delete_error
        return self.deleted_count

    def organize_media_by_tags(
        self,
        *,
        library_root: str,
        media_ids: list[str] | None = None,
    ) -> dict[str, str]:
        self.organize_calls.append(
            {
                'library_root': library_root,
                'media_ids': media_ids,
            }
        )
        if self.organize_error is not None:
            raise self.organize_error
        return dict(self.organize_result)

    def backfill_configured_tag_aliases(self) -> dict[str, int]:
        self.backfill_calls += 1
        return {'removedAliasCount': 0, 'migratedLinkCount': 0}


class _RecordingThumbnailService:
    def __init__(self) -> None:
        self.close_cached_pdf_documents_calls: list[list[str]] = []

    def close_cached_pdf_documents(self, paths: list[str]) -> None:
        self.close_cached_pdf_documents_calls.append(paths)


class _RecordingIndexService:
    def __init__(
        self,
        *,
        scan_error: Exception | None = None,
        rescan_error: Exception | None = None,
    ) -> None:
        self.scan_error = scan_error
        self.rescan_error = rescan_error
        self.scan_calls: list[str] = []
        self.rescan_calls: list[list[str]] = []
        self.index_calls: list[list[str]] = []

    def scan_folder(self, folder_raw: str) -> int:
        self.scan_calls.append(folder_raw)
        if self.scan_error is not None:
            raise self.scan_error
        return len(self.scan_calls)

    def index_files(self, paths: list[str]) -> int:
        normalized = [os.path.normpath(path) for path in paths]
        self.index_calls.append(normalized)
        for path in normalized:
            self.scan_calls.append(os.path.dirname(path))
        return len(normalized)

    def rescan_configured_roots(self, roots: list[str]) -> list[dict[str, int | str]]:
        self.rescan_calls.append(list(roots))
        if self.rescan_error is not None:
            raise self.rescan_error
        results: list[dict[str, int | str]] = []
        for root in roots:
            results.append({'folderRaw': root, 'count': self.scan_folder(root)})
        return results


class _UploadMetadataStore:
    def __init__(self) -> None:
        self.resolve_calls: list[dict[str, object | None]] = []
        self.add_tag_calls: list[dict[str, object]] = []
        self.organize_calls: list[dict[str, object]] = []
        self.media_tags: dict[str, list[dict[str, str]]] = {}

    def resolve_media_id(
        self,
        media_id: str | None,
        *,
        identity: dict[str, object] | None = None,
    ) -> str:
        self.resolve_calls.append({'media_id': media_id, 'identity': identity})
        aliases = (identity or {}).get('aliases') or []
        first_alias = aliases[0] if aliases else media_id or 'unknown'
        return f"mid:{os.path.basename(str(first_alias))}"

    def add_tags_to_media(
        self,
        media_id: str,
        tags: list[dict[str, str]],
        *,
        identity: dict[str, object] | None = None,
        request_id: str | None = None,
    ) -> str:
        self.add_tag_calls.append(
            {
                'media_id': media_id,
                'tags': tags,
                'identity': identity,
                'request_id': request_id,
            }
        )
        current = self.media_tags.setdefault(media_id, [])
        seen = {(entry['category'], entry['name']) for entry in current}
        for tag in tags:
            category = str(tag.get('category') or '').strip()
            name = str(tag.get('name') or '').strip()
            if not category or not name:
                continue
            key = (category, name)
            if key in seen:
                continue
            seen.add(key)
            current.append({'category': category, 'name': name})
        return media_id

    def get_tags_for_media(
        self,
        media_id: str,
        *,
        identity: dict[str, object] | None = None,
    ) -> list[dict[str, str]]:
        return [
            {
                'tagId': f"{entry['category']}:{entry['name']}",
                'category': entry['category'],
                'name': entry['name'],
            }
            for entry in self.media_tags.get(media_id, [])
        ]

    def organize_media_by_tags(
        self,
        *,
        library_root: str,
        media_ids: list[str],
    ) -> dict[str, str]:
        self.organize_calls.append(
            {
                'library_root': library_root,
                'media_ids': media_ids,
            }
        )
        if not media_ids:
            return {}
        source = os.path.join(library_root, 'sample.jpg')
        target = os.path.join(library_root, 'artists', 'Artist', 'Series', 'sample.jpg')
        return {source: target}


class _FakeUrlDownloadService:
    def __init__(
        self,
        *,
        result: UrlDownloadResult | None = None,
        error: Exception | None = None,
        on_call=None,
    ) -> None:
        self.result = result or UrlDownloadResult(imported_count=1)
        self.error = error
        self.on_call = on_call
        self.calls: list[dict[str, str]] = []

    async def download_url(
        self,
        *,
        source_url: str,
        destination_folder: str,
        options=None,
        on_event=None,
    ) -> UrlDownloadResult:
        self.calls.append(
            {
                'source_url': source_url,
                'destination_folder': destination_folder,
                'options': options,
            }
        )
        if self.on_call is not None:
            self.on_call(source_url, destination_folder)
        if self.error is not None:
            raise self.error
        return self.result


class _FakeUploadFile:
    def __init__(self, filename: str, data: bytes) -> None:
        self.filename = filename
        self._data = data
        self._offset = 0
        self.closed = False

    async def read(self, size: int = -1) -> bytes:
        if self._offset >= len(self._data):
            return b''
        if size < 0:
            size = len(self._data) - self._offset
        start = self._offset
        end = min(len(self._data), start + size)
        self._offset = end
        return self._data[start:end]

    async def close(self) -> None:
        self.closed = True


def _tiny_png_bytes() -> bytes:
    return base64.b64decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+cC1EAAAAASUVORK5CYII='
    )


def _request(
    metadata_store: object,
    *,
    index_service: object | None = None,
    media_roots: list[str] | None = None,
    thumbnail_service: object | None = None,
    url_download_service: object | None = None,
):
    return SimpleNamespace(
        app=SimpleNamespace(
            state=SimpleNamespace(
                metadata_store=metadata_store,
                index_service=index_service,
                thumbnail_service=thumbnail_service,
                settings=SimpleNamespace(media_roots=media_roots or []),
                url_download_service=url_download_service or _FakeUrlDownloadService(),
            )
        )
    )


class ActionsRoutesTest(unittest.TestCase):
    def test_apply_rename_passes_resolved_identity_to_metadata_store(self) -> None:
        store = _RecordingMetadataStore()
        request = _request(store)
        payload = RenameRequest(
            before=RenameSideDto(
                mediaId='old-id',
                path=r'C:\library\old.jpg',
            ),
            after=RenameSideDto(
                mediaId='new-id',
                path=r'C:\library\new.jpg',
            ),
        )

        response = apply_rename(request, payload)

        self.assertEqual(response.message, 'Rename completed')
        self.assertEqual(
            store.rename_calls,
            [
                {
                    'old_media_id': 'old-id',
                    'new_media_id': 'new-id',
                    'old_path': r'C:\library\old.jpg',
                    'new_path': r'C:\library\new.jpg',
                }
            ],
        )

    def test_apply_rename_propagates_metadata_errors(self) -> None:
        store = _RecordingMetadataStore(rename_error=bad_request('rename failed'))
        request = _request(store)
        payload = RenameRequest(oldPath=r'C:\library\old.jpg', newPath=r'C:\library\new.jpg')

        with self.assertRaises(ApiError):
            apply_rename(request, payload)

    def test_apply_rename_recovers_when_file_was_renamed_before_metadata_failed(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            old_path = os.path.join(temp_dir, 'old.pdf')
            new_path = os.path.join(temp_dir, 'new.pdf')
            with open(new_path, 'wb') as handle:
                handle.write(b'%PDF-1.4')
            store = _RecordingMetadataStore(rename_error=RuntimeError('db update failed'))
            index_service = _RecordingIndexService()
            request = _request(store, index_service=index_service)

            response = apply_rename(
                request,
                RenameRequest(oldPath=old_path, newPath=new_path),
            )

        self.assertEqual(response.message, 'Rename completed')
        self.assertEqual(index_service.scan_calls, [temp_dir])

    def test_apply_delete_passes_all_items_to_metadata_store(self) -> None:
        store = _RecordingMetadataStore(deleted_count=2)
        thumbnail_service = _RecordingThumbnailService()
        request = _request(store, thumbnail_service=thumbnail_service)
        payload = DeleteRequest(
            hardDelete=True,
            items=[
                DeleteItemRequest(mediaId='id-1', path=r'C:\library\one.jpg'),
                DeleteItemRequest(mediaId='id-2', path=r'C:\library\two.jpg'),
            ],
        )

        response = apply_delete(request, payload)

        self.assertEqual(response.message, 'Deleted 2 items')
        self.assertEqual(len(store.delete_calls), 1)
        self.assertTrue(store.delete_calls[0]['hard_delete'])
        self.assertEqual(len(store.delete_calls[0]['items']), 2)
        self.assertEqual(
            thumbnail_service.close_cached_pdf_documents_calls,
            [[r'C:\library\one.jpg', r'C:\library\two.jpg']],
        )

    def test_apply_delete_propagates_metadata_errors(self) -> None:
        store = _RecordingMetadataStore(delete_error=bad_request('delete failed'))
        request = _request(store)
        payload = DeleteRequest(mediaId='id-1', path=r'C:\library\one.jpg')

        with self.assertRaises(ApiError):
            apply_delete(request, payload)

    def test_request_rescan_scans_configured_roots(self) -> None:
        store = _RecordingMetadataStore()
        index_service = _RecordingIndexService()
        request = _request(
            store,
            index_service=index_service,
            media_roots=[r'C:\library', r'D:\books'],
        )

        response = request_rescan(request)

        self.assertEqual(response.message, 'Rescan completed: 3 items (tag aliases updated: 0)')
        self.assertEqual(index_service.rescan_calls, [[r'C:\library', r'D:\books']])
        self.assertEqual(index_service.scan_calls, [r'C:\library', r'D:\books'])
        self.assertEqual(store.backfill_calls, 1)

    def test_request_rescan_propagates_bad_request(self) -> None:
        store = _RecordingMetadataStore()
        index_service = _RecordingIndexService(scan_error=bad_request('missing root'))
        request = _request(store, index_service=index_service)

        with self.assertRaises(ApiError) as context:
            request_rescan(request, SimpleNamespace(folderRaw=r'Z:\missing'))

        self.assertEqual(context.exception.status_code, 400)
        self.assertEqual(context.exception.detail, 'missing root')

    def test_request_rescan_wraps_unexpected_errors(self) -> None:
        store = _RecordingMetadataStore()
        index_service = _RecordingIndexService(rescan_error=RuntimeError('db locked'))
        request = _request(
            store,
            index_service=index_service,
            media_roots=[r'C:\library'],
        )

        with self.assertRaises(ApiError) as context:
            request_rescan(request)

        self.assertEqual(context.exception.status_code, 500)
        self.assertEqual(context.exception.detail, '鬯ｯ・ｯ繝ｻ・ｯ郢晢ｽｻ繝ｻ・ｮ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｯ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｷ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ鬩搾ｽｵ繝ｻ・ｺ郢晢ｽｻ繝ｻ・､郢晢ｽｻ邵ｺ・､・つ鬯ｯ・ｯ繝ｻ・ｯ郢晢ｽｻ繝ｻ・ｯ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｮ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｦ鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｪ鬯ｯ・ｯ繝ｻ・ｩ髫ｰ・ｳ繝ｻ・ｾ郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｵ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｺ鬯ｯ・ｮ繝ｻ・ｯ髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｶ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｷ鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｹ鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｧ鬯ｯ・ｩ陝ｷ・｢繝ｻ・ｽ繝ｻ・｢鬮ｫ・ｴ髮懶ｽ｣繝ｻ・ｽ繝ｻ・｢驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｻ鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｭ鬯ｯ・ｯ繝ｻ・ｯ郢晢ｽｻ繝ｻ・ｩ鬮ｯ譎｢・ｽ・ｷ郢晢ｽｻ繝ｻ・｢驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・｢鬯ｯ・ｮ繝ｻ・ｫ郢晢ｽｻ繝ｻ・ｴ鬯ｮ・ｮ隲幢ｽｶ繝ｻ・ｽ繝ｻ・｣驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・｢鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・｣鬯ｯ・ｯ繝ｻ・ｯ郢晢ｽｻ繝ｻ・ｩ鬮ｯ譎｢・ｽ・ｷ郢晢ｽｻ繝ｻ・｢驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・｢鬯ｯ・ｮ繝ｻ・ｫ郢晢ｽｻ繝ｻ・ｴ鬯ｮ・ｮ隲幢ｽｶ繝ｻ・ｽ繝ｻ・｣驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・｢鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｳ鬯ｯ・ｯ繝ｻ・ｯ郢晢ｽｻ繝ｻ・ｩ鬮ｫ・ｰ繝ｻ・ｳ郢晢ｽｻ繝ｻ・ｾ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｵ鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｺ鬯ｯ・ｩ陝ｷ・｢繝ｻ・ｽ繝ｻ・｢鬮ｫ・ｴ髮懶ｽ｣繝ｻ・ｽ繝ｻ・｢驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｻ鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｫ鬯ｯ・ｯ繝ｻ・ｯ郢晢ｽｻ繝ｻ・ｮ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｯ鬯ｮ・ｫ繝ｻ・ｶ髴難ｽ｣陋帙・・ｽ・ｽ繝ｻ・･驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｻ鬯ｩ蟷｢・ｽ・｢郢晢ｽｻ繝ｻ・ｧ鬮ｫ・ｰ郢晢ｽｻ遶乗ｧｭ繝ｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｱ鬯ｯ・ｯ繝ｻ・ｯ郢晢ｽｻ繝ｻ・ｮ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｫ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｰ鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｨ鬯ｯ・ｯ繝ｻ・ｮ郢晢ｽｻ繝ｻ・ｯ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｷ鬯ｮ・｣髮具ｽｻ繝ｻ・ｽ繝ｻ・ｨ鬮ｯ讓奇ｽｻ繧托ｽｽ・ｽ繝ｻ・ｲ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｱ鬯ｯ・ｩ陝ｷ・｢繝ｻ・ｽ繝ｻ・｢鬮ｫ・ｴ髮懶ｽ｣繝ｻ・ｽ繝ｻ・｢驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｻ鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｰ鬯ｯ・ｯ繝ｻ・ｯ郢晢ｽｻ繝ｻ・ｩ鬮ｫ・ｰ繝ｻ・ｳ郢晢ｽｻ繝ｻ・ｾ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｵ鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｺ鬯ｯ・ｩ陝ｷ・｢繝ｻ・ｽ繝ｻ・｢鬮ｫ・ｴ髮懶ｽ｣繝ｻ・ｽ繝ｻ・｢驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｻ鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｾ鬯ｯ・ｯ繝ｻ・ｯ郢晢ｽｻ繝ｻ・ｩ鬮ｫ・ｰ繝ｻ・ｳ郢晢ｽｻ繝ｻ・ｾ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｵ鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｺ鬯ｯ・ｯ繝ｻ・ｮ郢晢ｽｻ繝ｻ・ｯ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｷ鬯ｮ・｣髮具ｽｻ繝ｻ・ｽ繝ｻ・ｨ鬮ｯ讓奇ｽｻ繧托ｽｽ・ｽ繝ｻ・ｲ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｱ鬯ｯ・ｯ繝ｻ・ｮ郢晢ｽｻ繝ｻ・ｫ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｨ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｳ鬯ｯ・ｩ陝ｷ・｢繝ｻ・ｽ繝ｻ・｢鬮ｫ・ｴ髮懶ｽ｣繝ｻ・ｽ繝ｻ・｢驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｻ db locked')

    def test_organize_library_calls_metadata_store_and_rescans(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            source = os.path.join(temp_dir, 'legacy-author', 'Artist', 'sample.pdf')
            target = os.path.join(temp_dir, 'author', 'Artist', 'sample.pdf')
            os.makedirs(os.path.dirname(source), exist_ok=True)
            with open(source, 'wb') as handle:
                handle.write(b'pdf')

            store = _RecordingMetadataStore(organize_result={source: target})
            index_service = _RecordingIndexService()
            request = _request(
                store,
                index_service=index_service,
                media_roots=[temp_dir],
            )

            response = organize_library(
                request,
                OrganizeLibraryRequest(folderRaw=temp_dir),
            )

            self.assertEqual(response.moved, {source: target})
            self.assertEqual(response.movedCount, 1)
            self.assertEqual(response.rescannedCount, 1)
            self.assertEqual(
                store.organize_calls,
                [{'library_root': temp_dir, 'media_ids': None}],
            )
            self.assertEqual(index_service.scan_calls, [temp_dir])

    def test_upload_files_applies_tags_and_organizes_imported_media(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            metadata_store = _UploadMetadataStore()
            index_service = _RecordingIndexService()
            request = _request(
                metadata_store,
                index_service=index_service,
                media_roots=[temp_dir],
            )
            upload = _FakeUploadFile('sample.jpg', b'abc123')

            response = asyncio.run(
                upload_files(
                    request,
                    folderRaw=temp_dir,
                    skipIfExists=True,
                    artistTag='Artist',
                    seriesTag='Series',
                    freeTagsJson='["bonus"]',
                    characterTagsJson='["Heroine"]',
                    targetCollection='library',
                    organizeAfterImport=True,
                    files=[upload],
                )
            )

            self.assertEqual(response['importedCount'], 1)
            self.assertEqual(response['skippedCount'], 0)
            self.assertEqual(response['taggedCount'], 1)
            self.assertEqual(response['organizedCount'], 1)
            self.assertEqual(response['rescannedCount'], 2)
            self.assertEqual(response['targetCollection'], 'library')
            self.assertEqual(index_service.scan_calls, [temp_dir, temp_dir])
            self.assertTrue(upload.closed)
            self.assertTrue(os.path.exists(os.path.join(temp_dir, 'sample.jpg')))
            self.assertEqual(len(metadata_store.resolve_calls), 1)
            self.assertEqual(len(metadata_store.add_tag_calls), 1)
            self.assertEqual(
                metadata_store.add_tag_calls[0]['tags'],
                [
                    {'category': 'artist', 'name': 'Artist'},
                    {'category': 'series', 'name': 'Series'},
                    {'category': 'character', 'name': 'Heroine'},
                    {'category': 'free', 'name': 'bonus'},
                ],
            )
            self.assertEqual(
                metadata_store.organize_calls,
                [
                    {
                        'library_root': temp_dir,
                        'media_ids': ['mid:sample.jpg'],
                    }
                ],
            )

    def test_upload_files_converts_uploaded_images_to_pdf_on_host(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            metadata_store = _UploadMetadataStore()
            index_service = _RecordingIndexService()
            request = _request(
                metadata_store,
                index_service=index_service,
                media_roots=[temp_dir],
            )
            png_bytes = _tiny_png_bytes()

            response = asyncio.run(
                upload_files(
                    request,
                    folderRaw=temp_dir,
                    skipIfExists=True,
                    artistTag='Artist',
                    freeTagsJson='["bonus"]',
                    convertToPdfOnHost=True,
                    hostPdfNameHint='Selected Folder',
                    files=[
                        _FakeUploadFile('001.png', png_bytes),
                        _FakeUploadFile('002.png', png_bytes),
                    ],
                )
            )

            expected_pdf = os.path.join(temp_dir, 'Selected Folder.pdf')
            self.assertEqual(response['importedCount'], 1)
            self.assertEqual(response['skippedCount'], 0)
            self.assertEqual(response['taggedCount'], 1)
            self.assertEqual(response['organizedCount'], 1)
            self.assertEqual(response['rescannedCount'], 2)
            self.assertTrue(os.path.exists(expected_pdf))
            self.assertFalse(os.path.exists(os.path.join(temp_dir, '001.png')))
            self.assertFalse(os.path.exists(os.path.join(temp_dir, '002.png')))
            self.assertEqual(index_service.index_calls, [[os.path.normpath(expected_pdf)]])
            self.assertEqual(
                metadata_store.add_tag_calls[0]['tags'],
                [
                    {'category': 'artist', 'name': 'Artist'},
                    {'category': 'free', 'name': 'bonus'},
                ],
            )
            self.assertEqual(
                response['attachedTagsByMedia'],
                {
                    'mid:Selected Folder.pdf': [
                        'artist:Artist',
                        'free:bonus',
                    ]
                },
            )

    def test_upload_files_uses_explicit_metadata_tags_even_when_source_relative_path_suggests_artist(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            metadata_store = _UploadMetadataStore()
            request = _request(
                metadata_store,
                index_service=_RecordingIndexService(),
                media_roots=[temp_dir],
            )
            upload = _FakeUploadFile('sample.pdf', b'%PDF-1.4')

            response = asyncio.run(
                upload_files(
                    request,
                    folderRaw=temp_dir,
                    skipIfExists=True,
                    artistTag='Client Artist',
                    seriesTag='Client Series',
                    freeTagsJson='["manual"]',
                    characterTagsJson='["Heroine"]',
                    sourceRelativePathsJson='["hitomi/[12345] Path Artist/sample.pdf"]',
                    files=[upload],
                )
            )

            self.assertEqual(response['importedCount'], 1)
            self.assertEqual(response['taggedCount'], 1)
            self.assertEqual(len(metadata_store.add_tag_calls), 1)
            self.assertTrue(str(response['requestId']).startswith('up-'))
            self.assertEqual(response['tagAttachSuccessCount'], 4)
            self.assertEqual(response['tagAttachFailureCount'], 0)
            self.assertEqual(
                response['attachedTagsByMedia'],
                {
                    'mid:sample.pdf': [
                        'artist:Client Artist',
                        'series:Client Series',
                        'character:Heroine',
                        'free:manual',
                    ]
                },
            )
            self.assertEqual(
                metadata_store.add_tag_calls[0]['tags'],
                [
                    {'category': 'artist', 'name': 'Client Artist'},
                    {'category': 'series', 'name': 'Client Series'},
                    {'category': 'character', 'name': 'Heroine'},
                    {'category': 'free', 'name': 'manual'},
                ],
            )

    def test_upload_files_does_not_infer_artist_from_source_relative_path_when_artist_missing(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            metadata_store = _UploadMetadataStore()
            request = _request(
                metadata_store,
                index_service=_RecordingIndexService(),
                media_roots=[temp_dir],
            )
            upload = _FakeUploadFile('sample.pdf', b'%PDF-1.4')

            response = asyncio.run(
                upload_files(
                    request,
                    folderRaw=temp_dir,
                    skipIfExists=True,
                    freeTagsJson='["manual"]',
                    sourceRelativePathsJson='["hitomi/[12345] Path Artist/sample.pdf"]',
                    files=[upload],
                )
            )

            self.assertEqual(response['importedCount'], 1)
            self.assertEqual(response['taggedCount'], 1)
            self.assertEqual(len(metadata_store.add_tag_calls), 1)
            self.assertEqual(
                metadata_store.add_tag_calls[0]['tags'],
                [
                    {'category': 'free', 'name': 'manual'},
                ],
            )

    def test_upload_files_preserves_file_specific_tags_without_source_path_inference(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            metadata_store = _UploadMetadataStore()
            request = _request(
                metadata_store,
                index_service=_RecordingIndexService(),
                media_roots=[temp_dir],
            )
            upload = _FakeUploadFile('sample.pdf', b'%PDF-1.4')

            response = asyncio.run(
                upload_files(
                    request,
                    folderRaw=temp_dir,
                    skipIfExists=True,
                    sourceRelativePathsJson=json.dumps(
                        ['hitomi/[12345] Path Artist/sample.pdf']
                    ),
                    fileTagsJson=json.dumps(
                        [[
                            {'category': 'artist', 'name': 'Local Artist'},
                            {'category': 'series', 'name': 'Local Series'},
                            {'category': 'character', 'name': 'Local Heroine'},
                            {'category': 'free', 'name': 'bonus'},
                        ]]
                    ),
                    files=[upload],
                )
            )

            self.assertEqual(response['importedCount'], 1)
            self.assertEqual(response['taggedCount'], 1)
            self.assertEqual(len(metadata_store.add_tag_calls), 1)
            self.assertEqual(response['tagAttachSuccessCount'], 4)
            self.assertEqual(
                response['attachedTagsByMedia'],
                {
                    'mid:sample.pdf': [
                        'artist:Local Artist',
                        'series:Local Series',
                        'character:Local Heroine',
                        'free:bonus',
                    ]
                },
            )
            self.assertEqual(
                metadata_store.add_tag_calls[0]['tags'],
                [
                    {'category': 'artist', 'name': 'Local Artist'},
                    {'category': 'series', 'name': 'Local Series'},
                    {'category': 'character', 'name': 'Local Heroine'},
                    {'category': 'free', 'name': 'bonus'},
                ],
            )

    def test_upload_files_prefers_original_display_name_for_unicode_file_name(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            metadata_store = _UploadMetadataStore()
            request = _request(
                metadata_store,
                index_service=_RecordingIndexService(),
                media_roots=[temp_dir],
            )
            upload = _FakeUploadFile('upload_001_deadbeef.pdf', b'%PDF-1.4')
            original_name = '鬯ｯ・ｯ繝ｻ・ｯ郢晢ｽｻ繝ｻ・ｩ鬮ｫ・ｰ繝ｻ・ｳ郢晢ｽｻ繝ｻ・ｾ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｵ鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｺ鬯ｯ・ｯ繝ｻ・ｩ髯晢ｽｷ繝ｻ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・｢鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｧ鬯ｯ・ｩ陝ｷ・｢繝ｻ・ｽ繝ｻ・｢鬮ｫ・ｴ髮懶ｽ｣繝ｻ・ｽ繝ｻ・｢驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｻ鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｼ鬯ｯ・ｮ繝ｻ・ｫ郢晢ｽｻ繝ｻ・ｶ鬮ｫ・ｰ隰ｦ・ｰ繝ｻ・ｽ繝ｻ・ｺ鬮ｫ・ｲ繝ｻ・ｷ郢晢ｽｻ繝ｻ・｣鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｸ鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｺ鬯ｯ・ｯ繝ｻ・ｩ髯晢ｽｷ繝ｻ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・｢鬯ｮ・ｫ繝ｻ・ｴ鬮ｮ諛ｶ・ｽ・｣郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・｢鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｻ鬯ｯ・ｯ繝ｻ・ｩ髯具ｽｹ郢晢ｽｻ繝ｻ・ｽ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｶ鬯ｮ・ｫ繝ｻ・ｰ郢晢ｽｻ繝ｻ・ｫ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｾ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｴ鬯ｯ・ｯ繝ｻ・ｯ郢晢ｽｻ繝ｻ・ｩ鬮ｫ・ｰ繝ｻ・ｳ郢晢ｽｻ繝ｻ・ｾ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｵ鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｺ鬯ｯ・ｯ繝ｻ・ｮ郢晢ｽｻ繝ｻ・ｯ鬮ｫ・ｲ陝ｷ・｢繝ｻ・ｽ繝ｻ・ｷ鬯ｯ・ｩ陟・侭魃ｵ驛｢譎｢・ｽ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・｣鬯ｯ・ｯ繝ｻ・ｯ郢晢ｽｻ繝ｻ・ｮ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｮ鬯ｮ・ｯ陷茨ｽｷ繝ｻ・ｽ繝ｻ・ｹ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｺ鬯ｯ・ｮ繝ｻ・ｫ郢晢ｽｻ繝ｻ・ｱ鬯ｮ・ｦ繝ｻ・ｮ髯ｷ・ｷ繝ｻ・ｶ驛｢譎｢・ｽ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・｢鬯ｯ・ｯ繝ｻ・ｯ郢晢ｽｻ繝ｻ・ｮ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｯ鬯ｮ・ｫ繝ｻ・ｴ髫ｰ・ｫ繝ｻ・ｾ郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｴ鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬯ｯ・ｯ繝ｻ・ｮ郢晢ｽｻ繝ｻ・ｴ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｸ鬯ｯ・ｩ陝ｷ・｢繝ｻ・ｽ繝ｻ・｢鬮ｫ・ｴ髮懶ｽ｣繝ｻ・ｽ繝ｻ・｢驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｻ鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｷ鬯ｯ・ｩ陝ｷ・｢繝ｻ・ｽ繝ｻ・｢鬮ｫ・ｴ髮懶ｽ｣繝ｻ・ｽ繝ｻ・｢驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｻ鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｷ鬯ｯ・ｯ繝ｻ・ｯ郢晢ｽｻ繝ｻ・ｮ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｯ鬯ｮ・ｫ繝ｻ・ｲ髯晢ｽｷ繝ｻ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｶ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｨ鬯ｯ・ｩ陝ｷ・｢繝ｻ・ｽ繝ｻ・｢鬮ｫ・ｴ髮懶ｽ｣繝ｻ・ｽ繝ｻ・｢驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｻ鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｨ.pdf'

            response = asyncio.run(
                upload_files(
                    request,
                    folderRaw=temp_dir,
                    skipIfExists=True,
                    originalDisplayNamesJson=json.dumps(
                        [original_name],
                        ensure_ascii=False,
                    ),
                    files=[upload],
                )
            )

            self.assertEqual(response['importedCount'], 1)
            self.assertTrue(upload.closed)
            self.assertTrue(os.path.exists(os.path.join(temp_dir, original_name)))

    def test_upload_files_keeps_unicode_name_when_relative_hint_contains_japanese_folder(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            metadata_store = _UploadMetadataStore()
            request = _request(
                metadata_store,
                index_service=_RecordingIndexService(),
                media_roots=[temp_dir],
            )
            upload = _FakeUploadFile('upload_001_cafebabe.png', b'png')
            original_name = '鬯ｯ・ｯ繝ｻ・ｯ郢晢ｽｻ繝ｻ・ｩ鬮ｯ譎｢・ｽ・ｷ郢晢ｽｻ繝ｻ・｢驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・｢鬯ｯ・ｮ繝ｻ・ｫ郢晢ｽｻ繝ｻ・ｴ鬮ｫ・ｰ繝ｻ・ｫ郢晢ｽｻ繝ｻ・ｾ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｴ鬯ｯ・ｩ陝ｷ・｢繝ｻ・ｽ繝ｻ・｢鬮ｫ・ｴ髮懶ｽ｣繝ｻ・ｽ繝ｻ・｢驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｻ鬯ｯ・ｯ繝ｻ・ｩ髫ｰ・ｳ繝ｻ・ｾ郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｵ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｺ鬯ｯ・ｮ繝ｻ・ｯ髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｶ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｷ鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｹ鬯ｯ・ｮ繝ｻ・ｫ郢晢ｽｻ繝ｻ・ｴ鬮ｯ譏ｴ繝ｻ繝ｻ繝ｻ・ｹ譎｢・ｽ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ鬮ｯ蜈ｷ・ｽ・ｻ郢晢ｽｻ繝ｻ・ｹ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｻ鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・､鬯ｯ・ｯ繝ｻ・ｯ郢晢ｽｻ繝ｻ・ｮ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｯ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｷ鬯ｯ・ｮ繝ｻ・ｯ髯ｷ・ｿ繝ｻ・･郢晢ｽｻ繝ｻ・ｹ郢晢ｽｻ繝ｻ・｢驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｵ鬯ｯ・ｩ陝ｷ・｢繝ｻ・ｽ繝ｻ・｢鬮ｫ・ｴ髮懶ｽ｣繝ｻ・ｽ繝ｻ・｢驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｻpng'

            response = asyncio.run(
                upload_files(
                    request,
                    folderRaw=temp_dir,
                    skipIfExists=True,
                    originalDisplayNamesJson=json.dumps(
                        [original_name],
                        ensure_ascii=False,
                    ),
                    sourceRelativePathsJson=json.dumps(
                        ['鬯ｯ・ｯ繝ｻ・ｯ郢晢ｽｻ繝ｻ・ｮ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｫ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｴ鬯ｯ・ｯ繝ｻ・ｯ郢晢ｽｻ繝ｻ・ｲ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｼ鬮ｯ讓奇ｽｻ繧托ｽｽ・ｽ繝ｻ・ｲ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・･鬯ｯ・ｯ繝ｻ・ｯ郢晢ｽｻ繝ｻ・ｮ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｫ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｴ鬯ｯ・ｮ繝ｻ・ｯ髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｷ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・｢鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｬ鬯ｯ・ｯ繝ｻ・ｯ郢晢ｽｻ繝ｻ・ｯ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｮ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｫ鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｱ鬯ｯ・ｯ繝ｻ・ｮ郢晢ｽｻ繝ｻ・ｫ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｶ鬯ｮ・ｫ繝ｻ・ｰ髯樊ｻゑｽｽ・ｲ郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｵ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｭ鬯ｯ・ｯ繝ｻ・ｩ髯晢ｽｷ繝ｻ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・｢鬯ｮ・ｫ繝ｻ・ｴ鬮ｮ諛ｶ・ｽ・｣郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・｢鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｵ鬯ｯ・ｯ繝ｻ・ｯ郢晢ｽｻ繝ｻ・ｩ鬮ｯ譎｢・ｽ・ｷ郢晢ｽｻ繝ｻ・｢驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・｢鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｧ鬯ｯ・ｩ陝ｷ・｢繝ｻ・ｽ繝ｻ・｢鬮ｫ・ｴ髮懶ｽ｣繝ｻ・ｽ繝ｻ・｢驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｻ鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｩ鬯ｯ・ｯ繝ｻ・ｯ郢晢ｽｻ繝ｻ・ｩ鬮ｯ譎｢・ｽ・ｷ郢晢ｽｻ繝ｻ・｢驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・｢鬯ｯ・ｮ繝ｻ・ｫ郢晢ｽｻ繝ｻ・ｴ鬯ｮ・ｮ隲幢ｽｶ繝ｻ・ｽ繝ｻ・｣驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・｢鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｫ鬯ｯ・ｯ繝ｻ・ｯ郢晢ｽｻ繝ｻ・ｩ鬮ｯ譎｢・ｽ・ｷ郢晢ｽｻ繝ｻ・｢驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・｢鬯ｯ・ｮ繝ｻ・ｫ郢晢ｽｻ繝ｻ・ｰ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｨ鬯ｯ・ｯ繝ｻ・ｲ髫ｰ繝ｻ竏槭・・ｽ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｴ驛｢譎｢・ｽ・ｻ驍ｵ・ｺ繝ｻ・､繝ｻ縺､ﾂ/鬯ｯ・ｯ繝ｻ・ｯ郢晢ｽｻ繝ｻ・ｩ鬮ｯ譎｢・ｽ・ｷ郢晢ｽｻ繝ｻ・｢驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・｢鬯ｯ・ｮ繝ｻ・ｫ郢晢ｽｻ繝ｻ・ｴ鬮ｫ・ｰ繝ｻ・ｫ郢晢ｽｻ繝ｻ・ｾ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｴ鬯ｯ・ｩ陝ｷ・｢繝ｻ・ｽ繝ｻ・｢鬮ｫ・ｴ髮懶ｽ｣繝ｻ・ｽ繝ｻ・｢驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｻ鬯ｯ・ｯ繝ｻ・ｩ髫ｰ・ｳ繝ｻ・ｾ郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｵ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｺ鬯ｯ・ｮ繝ｻ・ｯ髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｶ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｷ鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｹ鬯ｯ・ｮ繝ｻ・ｫ郢晢ｽｻ繝ｻ・ｴ鬮ｯ譏ｴ繝ｻ繝ｻ繝ｻ・ｹ譎｢・ｽ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ鬮ｯ蜈ｷ・ｽ・ｻ郢晢ｽｻ繝ｻ・ｹ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｻ鬯ｩ蟷｢・ｽ・｢髫ｴ雜｣・ｽ・｢郢晢ｽｻ繝ｻ・ｽ郢晢ｽｻ繝ｻ・ｻ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・､鬯ｯ・ｯ繝ｻ・ｯ郢晢ｽｻ繝ｻ・ｮ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｯ鬩幢ｽ｢隴趣ｽ｢繝ｻ・ｽ繝ｻ・ｻ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｷ鬯ｯ・ｮ繝ｻ・ｯ髯ｷ・ｿ繝ｻ・･郢晢ｽｻ繝ｻ・ｹ郢晢ｽｻ繝ｻ・｢驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｵ鬯ｯ・ｩ陝ｷ・｢繝ｻ・ｽ繝ｻ・｢鬮ｫ・ｴ髮懶ｽ｣繝ｻ・ｽ繝ｻ・｢驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｽ驛｢譎｢・ｽ・ｻ郢晢ｽｻ繝ｻ・ｻpng'],
                        ensure_ascii=False,
                    ),
                    files=[upload],
                )
            )

            self.assertEqual(response['importedCount'], 1)
            self.assertTrue(os.path.exists(os.path.join(temp_dir, original_name)))

    def test_download_url_applies_tags_after_downloader_creates_files(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            metadata_store = _UploadMetadataStore()
            index_service = _RecordingIndexService()

            def _create_downloaded_file(_: str, destination_folder: str) -> None:
                creator_dir = os.path.join(destination_folder, 'patreon', 'artist [123]')
                os.makedirs(creator_dir, exist_ok=True)
                with open(os.path.join(creator_dir, 'sample.jpg'), 'wb') as handle:
                    handle.write(b'abc123')

            downloader = _FakeUrlDownloadService(
                result=UrlDownloadResult(imported_count=1, skipped_count=0, failed_count=0),
                on_call=_create_downloaded_file,
            )
            request = _request(
                metadata_store,
                index_service=index_service,
                media_roots=[temp_dir],
                url_download_service=downloader,
            )

            response = asyncio.run(
                download_url(
                    request,
                    DownloadUrlRequest(
                        folderRaw=temp_dir,
                        url='https://kemono.su/patreon/user/123/post/456',
                        artistTag='Artist',
                        seriesTag='Series',
                        freeTags=['bonus'],
                        characterTags=['Heroine'],
                        targetCollection='library',
                        organizeAfterImport=True,
                    ),
                )
            )

            self.assertEqual(response.importedCount, 1)
            self.assertEqual(response.skippedCount, 0)
            self.assertEqual(response.failedCount, 0)
            self.assertEqual(response.taggedCount, 1)
            self.assertEqual(response.organizedCount, 1)
            self.assertEqual(response.rescannedCount, 2)
            self.assertEqual(response.targetCollection, 'library')
            self.assertEqual(index_service.scan_calls, [temp_dir, temp_dir])
            self.assertEqual(len(downloader.calls), 1)
            self.assertEqual(downloader.calls[0]['source_url'], 'https://kemono.su/patreon/user/123/post/456')
            self.assertTrue(downloader.calls[0]['destination_folder'].startswith(temp_dir))
            self.assertTrue(
                os.path.basename(downloader.calls[0]['destination_folder']).startswith(
                    '.download-url-stage-'
                )
            )
            self.assertEqual(len(metadata_store.add_tag_calls), 1)
            self.assertEqual(
                metadata_store.add_tag_calls[0]['tags'],
                [
                    {'category': 'artist', 'name': 'Artist'},
                    {'category': 'series', 'name': 'Series'},
                    {'category': 'character', 'name': 'Heroine'},
                    {'category': 'free', 'name': 'bonus'},
                ],
            )
            self.assertTrue(os.path.exists(os.path.join(temp_dir, 'sample.jpg')))
            self.assertFalse(os.path.exists(os.path.join(temp_dir, 'patreon')))

    def test_download_url_flattens_hitomi_pdf_and_applies_inferred_tags(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            metadata_store = _UploadMetadataStore()
            index_service = _RecordingIndexService()

            def _create_downloaded_file(_: str, destination_folder: str) -> None:
                artist_dir = os.path.join(destination_folder, 'hitomi', '[12345] ArtistName')
                gallery_dir = os.path.join(artist_dir, '[20241105] [3114110] Sample Title')
                os.makedirs(gallery_dir, exist_ok=True)
                with open(os.path.join(gallery_dir, '001.jpg'), 'wb') as handle:
                    handle.write(b'jpg')
                with open(os.path.join(artist_dir, 'Sample Title.pdf'), 'wb') as handle:
                    handle.write(b'%PDF-1.4')

            downloader = _FakeUrlDownloadService(
                result=UrlDownloadResult(
                    imported_count=1,
                    skipped_count=0,
                    failed_count=0,
                    hitomi_metadata_by_relative_path={
                        'hitomi/[12345] artistname/sample title.pdf': {
                            'artists': ['ArtistName', 'CoArtist'],
                            'series': ['Original Series'],
                            'characters': ['Heroine'],
                            'tags': ['big breasts', 'school uniform'],
                        },
                    },
                ),
                on_call=_create_downloaded_file,
            )
            request = _request(
                metadata_store,
                index_service=index_service,
                media_roots=[temp_dir],
                url_download_service=downloader,
            )

            response = asyncio.run(
                download_url(
                    request,
                    DownloadUrlRequest(
                        folderRaw=temp_dir,
                        url='https://hitomi.la/reader/123456.html',
                    ),
                )
            )

            self.assertEqual(response.importedCount, 1)
            self.assertEqual(response.taggedCount, 1)
            self.assertEqual(response.organizedCount, 1)
            self.assertEqual(response.rescannedCount, 2)
            self.assertEqual(index_service.scan_calls, [temp_dir, temp_dir])
            self.assertTrue(os.path.exists(os.path.join(temp_dir, 'Sample Title.pdf')))
            self.assertFalse(os.path.exists(os.path.join(temp_dir, '[20241105] [3114110] Sample Title', '001.jpg')))
            self.assertFalse(os.path.exists(os.path.join(temp_dir, 'hitomi')))
            self.assertEqual(
                metadata_store.add_tag_calls[0]['tags'],
                [
                    {'category': 'artist', 'name': 'ArtistName'},
                    {'category': 'artist', 'name': 'CoArtist'},
                    {'category': 'series', 'name': 'Original Series'},
                    {'category': 'character', 'name': 'Heroine'},
                    {'category': 'free', 'name': 'big breasts'},
                    {'category': 'free', 'name': 'school uniform'},
                    {'category': 'mediaType', 'name': 'hitomi'},
                ],
            )

    def test_download_url_keeps_multiple_gifs_as_collection(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            metadata_store = _UploadMetadataStore()
            index_service = _RecordingIndexService()

            def _create_downloaded_file(_: str, destination_folder: str) -> None:
                gallery_dir = os.path.join(destination_folder, 'site', 'Sample GIF')
                os.makedirs(gallery_dir, exist_ok=True)
                with open(os.path.join(gallery_dir, '001.gif'), 'wb') as handle:
                    handle.write(_GIF_1X1)
                with open(os.path.join(gallery_dir, '002.gif'), 'wb') as handle:
                    handle.write(_GIF_1X1)

            downloader = _FakeUrlDownloadService(
                result=UrlDownloadResult(
                    imported_count=2,
                    skipped_count=0,
                    failed_count=0,
                ),
                on_call=_create_downloaded_file,
            )
            request = _request(
                metadata_store,
                index_service=index_service,
                media_roots=[temp_dir],
                url_download_service=downloader,
            )

            response = asyncio.run(
                download_url(
                    request,
                    DownloadUrlRequest(
                        folderRaw=temp_dir,
                        url='https://example.test/gallery/animated',
                    ),
                )
            )

            collection_path = os.path.join(temp_dir, 'Sample GIF')
            self.assertEqual(response.importedCount, 2)
            self.assertEqual(response.taggedCount, 1)
            self.assertEqual(response.organizedCount, 1)
            self.assertEqual(response.rescannedCount, 2)
            self.assertTrue(os.path.isdir(collection_path))
            self.assertTrue(
                os.path.exists(os.path.join(collection_path, '001.gif'))
            )
            self.assertTrue(
                os.path.exists(os.path.join(collection_path, '002.gif'))
            )
            self.assertFalse(os.path.exists(os.path.join(temp_dir, 'site')))
            self.assertEqual(metadata_store.add_tag_calls[0]['media_id'], 'mid:Sample GIF')
            self.assertEqual(
                metadata_store.add_tag_calls[0]['tags'],
                [
                    {'category': 'mediaType', 'name': 'GIF'},
                ],
            )
            self.assertEqual(
                metadata_store.organize_calls[0]['media_ids'],
                ['mid:Sample GIF'],
            )

    def test_download_url_renames_duplicate_hitomi_pdf_names_in_same_batch(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            metadata_store = _UploadMetadataStore()
            index_service = _RecordingIndexService()

            def _create_downloaded_file(_: str, destination_folder: str) -> None:
                first_artist_dir = os.path.join(destination_folder, 'hitomi', '[11111] ArtistOne')
                first_gallery_dir = os.path.join(first_artist_dir, '[20241105] [3114110] Same Title')
                os.makedirs(first_gallery_dir, exist_ok=True)
                with open(os.path.join(first_gallery_dir, '001.jpg'), 'wb') as handle:
                    handle.write(b'jpg')
                with open(os.path.join(first_artist_dir, 'Same Title.pdf'), 'wb') as handle:
                    handle.write(b'%PDF-1.4 first')

                second_artist_dir = os.path.join(destination_folder, 'hitomi', '[22222] ArtistTwo')
                second_gallery_dir = os.path.join(second_artist_dir, '[20241106] [3114111] Same Title')
                os.makedirs(second_gallery_dir, exist_ok=True)
                with open(os.path.join(second_gallery_dir, '001.jpg'), 'wb') as handle:
                    handle.write(b'jpg')
                with open(os.path.join(second_artist_dir, 'Same Title.pdf'), 'wb') as handle:
                    handle.write(b'%PDF-1.4 second')

            downloader = _FakeUrlDownloadService(
                result=UrlDownloadResult(
                    imported_count=2,
                    skipped_count=0,
                    failed_count=0,
                    hitomi_metadata_by_relative_path={
                        'hitomi/[11111] artistone/same title.pdf': {
                            'artists': ['ArtistOne'],
                            'series': ['Series One'],
                        },
                        'hitomi/[22222] artisttwo/same title.pdf': {
                            'artists': ['ArtistTwo'],
                            'series': ['Series Two'],
                        },
                    },
                ),
                on_call=_create_downloaded_file,
            )
            request = _request(
                metadata_store,
                index_service=index_service,
                media_roots=[temp_dir],
                url_download_service=downloader,
            )

            response = asyncio.run(
                download_url(
                    request,
                    DownloadUrlRequest(
                        folderRaw=temp_dir,
                        url=(
                            'https://hitomi.la/search.html?'
                            'artist%3Aexample%20language%3Ajapanese%20type%3Adoujinshi'
                        ),
                    ),
                )
            )

            self.assertEqual(response.importedCount, 2)
            self.assertEqual(response.taggedCount, 2)
            self.assertTrue(os.path.exists(os.path.join(temp_dir, 'Same Title.pdf')))
            self.assertTrue(os.path.exists(os.path.join(temp_dir, 'Same Title (2).pdf')))
            self.assertEqual(
                {call['media_id'] for call in metadata_store.add_tag_calls},
                {'mid:Same Title.pdf', 'mid:Same Title (2).pdf'},
            )

    def test_download_url_applies_ddd_smart_media_type_to_images(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            metadata_store = _UploadMetadataStore()
            index_service = _RecordingIndexService()

            def _create_downloaded_file(_: str, destination_folder: str) -> None:
                with open(os.path.join(destination_folder, 'downloaded.jpg'), 'wb') as handle:
                    handle.write(b'abc123')

            downloader = _FakeUrlDownloadService(
                result=UrlDownloadResult(imported_count=1, skipped_count=0, failed_count=0),
                on_call=_create_downloaded_file,
            )
            request = _request(
                metadata_store,
                index_service=index_service,
                media_roots=[temp_dir],
                url_download_service=downloader,
            )

            response = asyncio.run(
                download_url(
                    request,
                    DownloadUrlRequest(
                        folderRaw=temp_dir,
                        url='https://ddd-smart.net/doujinshi3/show-m.php?g=20260411&dir=0058&page=0',
                    ),
                )
            )

            self.assertEqual(response.importedCount, 1)
            self.assertEqual(response.taggedCount, 1)
            self.assertEqual(response.organizedCount, 1)
            self.assertEqual(response.rescannedCount, 2)
            self.assertEqual(index_service.scan_calls, [temp_dir, temp_dir])
            self.assertEqual(len(metadata_store.add_tag_calls), 1)
            self.assertEqual(
                metadata_store.add_tag_calls[0]['tags'],
                [
                    {'category': 'mediaType', 'name': 'ddd-smart'},
                ],
            )

    def test_download_url_surfaces_downloader_errors_as_api_errors(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            request = _request(
                _UploadMetadataStore(),
                index_service=_RecordingIndexService(),
                media_roots=[temp_dir],
                url_download_service=_FakeUrlDownloadService(
                    error=UrlDownloadError('download failed'),
                ),
            )

            with self.assertRaises(ApiError):
                asyncio.run(
                    download_url(
                        request,
                        DownloadUrlRequest(
                            folderRaw=temp_dir,
                            url='https://kemono.su/patreon/user/123/post/456',
                        ),
                    )
                )


if __name__ == '__main__':
    unittest.main()



