from types import SimpleNamespace
import unittest

from starlette.datastructures import QueryParams

from server.api.routes_tags import delete_master_tag, get_tags_for_item, merge_tag_master
from server.models.dto import MergeTagMasterRequest


class _RecordingMetadataStore:
    def __init__(self) -> None:
        self.resolve_calls: list[dict[str, object | None]] = []
        self.get_tag_calls: list[dict[str, object | None]] = []
        self.deleted_tag_ids: list[str] = []
        self.merge_calls: list[dict[str, object]] = []

    def resolve_media_id(
        self,
        media_id: str | None,
        *,
        identity: dict[str, object] | None = None,
    ) -> str:
        self.resolve_calls.append({'media_id': media_id, 'identity': identity})
        return 'resolved-media-id'

    def get_tags_for_media(
        self,
        media_id: str,
        *,
        identity: dict[str, object] | None = None,
    ) -> list[dict[str, str]]:
        self.get_tag_calls.append({'media_id': media_id, 'identity': identity})
        return [{'tagId': 'artist:1', 'name': 'Artist', 'category': 'artist'}]

    def delete_tag_master(self, tag_id: str) -> int:
        self.deleted_tag_ids.append(tag_id)
        return 1

    def merge_tag_master(self, **kwargs: object) -> dict[str, str]:
        self.merge_calls.append(kwargs)
        return {'tagId': 'artist:new', 'name': 'New artist', 'category': 'artist'}


def _request(query: str, metadata_store: _RecordingMetadataStore):
    return SimpleNamespace(
        query_params=QueryParams(query),
        app=SimpleNamespace(
            state=SimpleNamespace(
                metadata_store=metadata_store,
            )
        ),
    )


class TagsRoutesTest(unittest.TestCase):
    def test_get_tags_for_item_resolves_media_from_query_identity(self) -> None:
        store = _RecordingMetadataStore()
        request = _request(
            'normalizedPath=c%3A%5Clibrary%5Csample.jpg&relativePathHint=sample.jpg&sizeBytes=12&modifiedEpochMs=1234&alias0=C%3A%5Clibrary%5Csample.jpg',
            store,
        )

        response = get_tags_for_item(request, 'stable-id')

        self.assertEqual(response.mediaId, 'resolved-media-id')
        self.assertEqual(response.items[0].name, 'Artist')
        self.assertEqual(len(store.resolve_calls), 1)
        self.assertEqual(len(store.get_tag_calls), 1)
        identity = store.resolve_calls[0]['identity']
        self.assertEqual(identity['normalizedPath'], r'c:\library\sample.jpg')
        self.assertEqual(identity['relativePathHint'], 'sample.jpg')
        self.assertEqual(identity['sizeBytes'], 12)
        self.assertEqual(identity['modifiedEpochMs'], 1234)
        self.assertEqual(identity['aliases'], [r'C:\library\sample.jpg'])

    def test_delete_master_tag_forwards_to_metadata_store(self) -> None:
        store = _RecordingMetadataStore()
        request = _request('', store)

        response = delete_master_tag(request, 'artist:123')

        self.assertTrue(response['ok'])
        self.assertEqual(store.deleted_tag_ids, ['artist:123'])

    def test_merge_master_tag_forwards_to_metadata_store(self) -> None:
        store = _RecordingMetadataStore()
        response = merge_tag_master(
            _request('', store),
            MergeTagMasterRequest(
                tagIds=['artist:old'],
                category='artist',
                targetName='New artist',
            ),
        )

        self.assertEqual(response.items[0].tagId, 'artist:new')
        self.assertEqual(
            store.merge_calls,
            [{'tag_ids': ['artist:old'], 'category': 'artist', 'target_name': 'New artist'}],
        )


if __name__ == '__main__':
    unittest.main()
