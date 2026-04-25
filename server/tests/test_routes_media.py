from types import SimpleNamespace
from datetime import datetime, timezone
import unittest

from starlette.datastructures import QueryParams

from server.api.routes_media import get_media_meta


class _RecordingMetadataStore:
    def __init__(self) -> None:
        self.resolve_calls: list[dict[str, object | None]] = []
        self.stats_calls: list[dict[str, object | None]] = []

    def resolve_media_id(
        self,
        media_id: str | None,
        *,
        identity: dict[str, object] | None = None,
    ) -> str:
        self.resolve_calls.append({"media_id": media_id, "identity": identity})
        return "resolved-media-id"

    def get_media_stats(
        self,
        media_id: str,
        *,
        identity: dict[str, object] | None = None,
    ) -> dict[str, object]:
        self.stats_calls.append({"media_id": media_id, "identity": identity})
        return {
            "addedAt": datetime(2026, 1, 1, tzinfo=timezone.utc),
            "lastViewedAt": None,
            "viewCount": 0,
        }


class _RecordingStreamService:
    def __init__(self) -> None:
        self.meta_calls: list[str] = []

    def get_media_meta(self, media_id: str) -> dict[str, object]:
        self.meta_calls.append(media_id)
        return {
            "mediaId": media_id,
            "displayName": "sample.pdf",
            "kind": "pdf",
            "mimeType": "application/pdf",
            "sizeBytes": 12,
            "modifiedAt": None,
            "etag": None,
            "supportsRange": True,
        }


class _RecordingThumbnailService:
    def __init__(self) -> None:
        self.page_count_calls: list[str] = []

    def get_pdf_page_count(self, media_id: str) -> int:
        self.page_count_calls.append(media_id)
        return 5


def _request(query: str):
    metadata_store = _RecordingMetadataStore()
    stream_service = _RecordingStreamService()
    thumbnail_service = _RecordingThumbnailService()
    request = SimpleNamespace(
        query_params=QueryParams(query),
        app=SimpleNamespace(
            state=SimpleNamespace(
                metadata_store=metadata_store,
                stream_service=stream_service,
                thumbnail_service=thumbnail_service,
            )
        ),
    )
    return request, metadata_store, stream_service, thumbnail_service


class MediaRoutesTest(unittest.TestCase):
    def test_get_media_meta_resolves_media_from_query_identity(self) -> None:
        request, store, stream_service, thumbnail_service = _request(
            "normalizedPath=c%3A%5C%5Clibrary%5C%5Csample.pdf"
            "&relativePathHint=sample.pdf"
            "&sizeBytes=12"
            "&modifiedEpochMs=1234"
            "&alias0=C%3A%5C%5Clibrary%5C%5Csample.pdf"
        )

        response = get_media_meta(request, "stale-media-id")

        self.assertEqual(response.mediaId, "resolved-media-id")
        self.assertEqual(stream_service.meta_calls, ["resolved-media-id"])
        self.assertEqual(thumbnail_service.page_count_calls, ["resolved-media-id"])
        self.assertEqual(len(store.resolve_calls), 1)
        identity = store.resolve_calls[0]["identity"]
        self.assertEqual(identity["normalizedPath"], r"c:\\library\\sample.pdf")
        self.assertEqual(identity["relativePathHint"], "sample.pdf")
        self.assertEqual(identity["sizeBytes"], 12)
        self.assertEqual(identity["modifiedEpochMs"], 1234)
        self.assertEqual(identity["aliases"], [r"C:\\library\\sample.pdf"])


if __name__ == "__main__":
    unittest.main()
