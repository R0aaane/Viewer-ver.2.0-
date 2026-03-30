import asyncio
import json
import os
import tempfile
from types import SimpleNamespace
import unittest

from server.api.routes_actions import apply_delete, apply_rename, download_url, request_rescan, upload_files
from server.core.errors import ApiError, bad_request
from server.models.dto import (
    DeleteItemRequest,
    DeleteRequest,
    DownloadUrlRequest,
    RenameRequest,
    RenameSideDto,
)
from server.services.url_download_service import UrlDownloadError, UrlDownloadResult


class _RecordingMetadataStore:
    def __init__(
        self,
        *,
        rename_error: Exception | None = None,
        delete_error: Exception | None = None,
        deleted_count: int = 1,
    ) -> None:
        self.rename_error = rename_error
        self.delete_error = delete_error
        self.deleted_count = deleted_count
        self.rename_calls: list[dict[str, object | None]] = []
        self.delete_calls: list[dict[str, object]] = []

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

    def scan_folder(self, folder_raw: str) -> int:
        self.scan_calls.append(folder_raw)
        if self.scan_error is not None:
            raise self.scan_error
        return len(self.scan_calls)

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
    ) -> str:
        self.add_tag_calls.append(
            {
                'media_id': media_id,
                'tags': tags,
                'identity': identity,
            }
        )
        return media_id

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


def _request(
    metadata_store: object,
    *,
    index_service: object | None = None,
    media_roots: list[str] | None = None,
    url_download_service: object | None = None,
):
    return SimpleNamespace(
        app=SimpleNamespace(
            state=SimpleNamespace(
                metadata_store=metadata_store,
                index_service=index_service,
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

        self.assertEqual(response.message, 'リネームしました')
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

    def test_apply_delete_passes_all_items_to_metadata_store(self) -> None:
        store = _RecordingMetadataStore(deleted_count=2)
        request = _request(store)
        payload = DeleteRequest(
            hardDelete=True,
            items=[
                DeleteItemRequest(mediaId='id-1', path=r'C:\library\one.jpg'),
                DeleteItemRequest(mediaId='id-2', path=r'C:\library\two.jpg'),
            ],
        )

        response = apply_delete(request, payload)

        self.assertEqual(response.message, '削除しました (2 件)')
        self.assertEqual(len(store.delete_calls), 1)
        self.assertTrue(store.delete_calls[0]['hard_delete'])
        self.assertEqual(len(store.delete_calls[0]['items']), 2)

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

        self.assertEqual(response.message, '再スキャンが完了しました: 3 件')
        self.assertEqual(index_service.rescan_calls, [[r'C:\library', r'D:\books']])
        self.assertEqual(index_service.scan_calls, [r'C:\library', r'D:\books'])

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
        self.assertEqual(context.exception.detail, '再スキャンに失敗しました: db locked')

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

    def test_upload_files_skips_inferred_tags_for_non_hitomi_pdf(self) -> None:
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
                    sourceRelativePathsJson='["kemono/patreon/[12345] ArtistName/sample.pdf"]',
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

    def test_upload_files_infers_tags_for_hitomi_pdf_from_source_relative_paths(self) -> None:
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
                    sourceRelativePathsJson='["hitomi/[12345] ArtistName/sample.pdf"]',
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
                    {'category': 'artist', 'name': 'ArtistName'},
                    {'category': 'mediaType', 'name': 'hitomi'},
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
            original_name = 'あいうえお_漢字混在.pdf'

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
            original_name = 'テスト画像.png'

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
                        ['日本語フォルダ/テスト画像.png'],
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
            self.assertEqual(downloader.calls[0]['destination_folder'], temp_dir)
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
                os.makedirs(artist_dir, exist_ok=True)
                with open(os.path.join(artist_dir, 'sample.pdf'), 'wb') as handle:
                    handle.write(b'%PDF-1.4')

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
                        url='https://hitomi.la/reader/123456.html',
                    ),
                )
            )

            self.assertEqual(response.importedCount, 1)
            self.assertEqual(response.taggedCount, 1)
            self.assertEqual(response.organizedCount, 0)
            self.assertEqual(response.rescannedCount, 1)
            self.assertEqual(index_service.scan_calls, [temp_dir])
            self.assertTrue(os.path.exists(os.path.join(temp_dir, 'sample.pdf')))
            self.assertFalse(os.path.exists(os.path.join(temp_dir, 'hitomi')))
            self.assertEqual(
                metadata_store.add_tag_calls[0]['tags'],
                [
                    {'category': 'artist', 'name': 'ArtistName'},
                    {'category': 'mediaType', 'name': 'hitomi'},
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