from types import SimpleNamespace
import unittest

from server.api.routes_search import list_folders


class _RecordingMetadataStore:
    def __init__(self, indexed_folders: list[dict[str, object | None]]) -> None:
        self.indexed_folders = indexed_folders

    def list_indexed_folders(self) -> list[dict[str, object | None]]:
        return list(self.indexed_folders)


def _request(indexed_folders: list[dict[str, object | None]], media_roots: list[str]):
    return SimpleNamespace(
        app=SimpleNamespace(
            state=SimpleNamespace(
                metadata_store=_RecordingMetadataStore(indexed_folders),
                settings=SimpleNamespace(media_roots=media_roots),
            )
        )
    )


class SearchRoutesTest(unittest.TestCase):
    def test_list_folders_includes_configured_media_roots_before_indexed_entries(self) -> None:
        request = _request(
            indexed_folders=[
                {
                    'folderRaw': r'C:\library',
                    'displayName': 'Library',
                    'lastScannedAt': None,
                },
                {
                    'folderRaw': r'C:\extra',
                    'displayName': 'Extra',
                    'lastScannedAt': None,
                },
            ],
            media_roots=[r'C:\library', r'C:\empty-root'],
        )

        response = list_folders(request)

        self.assertEqual(
            [entry.folderRaw for entry in response.items],
            [r'C:\library', r'C:\empty-root', r'C:\extra'],
        )
        self.assertEqual(response.items[1].displayName, 'empty-root')


if __name__ == '__main__':
    unittest.main()
