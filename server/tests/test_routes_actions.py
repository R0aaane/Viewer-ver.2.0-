from types import SimpleNamespace
import unittest

from server.api.routes_actions import apply_delete, apply_rename
from server.core.errors import ApiError, bad_request
from server.models.dto import DeleteItemRequest, DeleteRequest, RenameRequest, RenameSideDto


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


def _request(metadata_store: _RecordingMetadataStore):
    return SimpleNamespace(
        app=SimpleNamespace(
            state=SimpleNamespace(
                metadata_store=metadata_store,
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

        self.assertEqual(response.message, 'リネームを反映しました')
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

        self.assertEqual(response.message, '削除を反映しました (2 件)')
        self.assertEqual(len(store.delete_calls), 1)
        self.assertTrue(store.delete_calls[0]['hard_delete'])
        self.assertEqual(len(store.delete_calls[0]['items']), 2)

    def test_apply_delete_propagates_metadata_errors(self) -> None:
        store = _RecordingMetadataStore(delete_error=bad_request('delete failed'))
        request = _request(store)
        payload = DeleteRequest(mediaId='id-1', path=r'C:\library\one.jpg')

        with self.assertRaises(ApiError):
            apply_delete(request, payload)


if __name__ == '__main__':
    unittest.main()
