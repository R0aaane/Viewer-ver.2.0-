import tempfile
import unittest

from server.services.url_download_service import (
    UrlDownloadOptions,
    UrlDownloadResult,
    UrlDownloadService,
    _ResolvedDirectUrl,
)


class _FakeHeaders:
    def __init__(
        self,
        *,
        content_type: str = "application/pdf",
        disposition: str | None = None,
    ) -> None:
        self._content_type = content_type
        self._values: dict[str, str] = {}
        if disposition is not None:
            self._values["content-disposition"] = disposition

    def get(self, key: str, default: str | None = None) -> str | None:
        return self._values.get(key, default)

    def get_content_type(self) -> str:
        return self._content_type


class _FakeResponse:
    def __init__(
        self,
        *,
        content_type: str = "application/pdf",
        disposition: str | None = None,
    ) -> None:
        self.headers = _FakeHeaders(
            content_type=content_type,
            disposition=disposition,
        )


class _RecordingUrlDownloadService(UrlDownloadService):
    def __init__(self) -> None:
        super().__init__()
        self.direct_calls: list[dict[str, object]] = []
        self.launcher_calls: list[dict[str, object]] = []

    def _resolve_special_direct_url(self, raw_url: str) -> _ResolvedDirectUrl | None:
        if "ddd-smart.net" not in raw_url:
            return None
        return _ResolvedDirectUrl(
            url="https://cdn.ddd-smart.net/sample.pdf",
            metadata={"media_type": "ddd-smart"},
        )

    async def _run_with_launcher(self, **kwargs) -> UrlDownloadResult:
        self.launcher_calls.append(kwargs)
        return UrlDownloadResult(imported_count=2)

    async def _run_direct_url_download_urls(self, **kwargs) -> UrlDownloadResult:
        self.direct_calls.append(kwargs)
        return UrlDownloadResult(
            imported_count=1,
            hitomi_metadata_by_relative_path={
                "sample.pdf": {"media_type": "ddd-smart"},
            },
        )


class _HitomiSearchRecordingUrlDownloadService(_RecordingUrlDownloadService):
    def _download_hitomi_nozomi_gallery_ids(self, state) -> list[int]:
        key = (
            state.area,
            state.tag,
            state.language,
            state.order_by,
            state.order_by_key,
        )
        return {
            ("artist", "chilt", "all", "date", "added"): [400, 300, 200, 100],
            ("all", "index", "japanese", "date", "added"): [300, 250, 200],
            ("type", "doujinshi", "all", "date", "added"): [500, 300, 200],
        }.get(key, [])


class UrlDownloadServiceTest(unittest.TestCase):
    def test_uses_metadata_title_when_download_name_is_all(self) -> None:
        service = UrlDownloadService()

        file_name = service._build_download_file_name(
            "https://cdn.ddd-smart.net/all.pdf",
            _FakeResponse(),
            sequence=1,
            metadata={"japanese_title": "Sample Title"},
        )

        self.assertEqual(file_name, "Sample Title.pdf")

    def test_keeps_non_generic_download_name_when_present(self) -> None:
        service = UrlDownloadService()

        file_name = service._build_download_file_name(
            "https://cdn.ddd-smart.net/original.pdf",
            _FakeResponse(),
            sequence=1,
            metadata={"japanese_title": "Sample Title"},
        )

        self.assertEqual(file_name, "original.pdf")

    def test_routes_ddd_smart_show_page_to_direct_downloader(self) -> None:
        service = _RecordingUrlDownloadService()
        with tempfile.TemporaryDirectory() as temp_dir:
            result = service_loop(
                service.download_url(
                    source_url="https://ddd-smart.net/doujinshi3/show-m.php?g=20260411&dir=0058&page=0",
                    destination_folder=temp_dir,
                    options=UrlDownloadOptions(),
                )
            )

        self.assertEqual(result.imported_count, 1)
        self.assertEqual(len(service.launcher_calls), 0)
        self.assertEqual(len(service.direct_calls), 1)
        self.assertEqual(
            service.direct_calls[0]["urls"],
            ["https://cdn.ddd-smart.net/sample.pdf"],
        )
        self.assertEqual(
            service.direct_calls[0]["metadata_by_url"],
            {"https://cdn.ddd-smart.net/sample.pdf": {"media_type": "ddd-smart"}},
        )

    def test_merges_launcher_and_direct_results(self) -> None:
        service = _RecordingUrlDownloadService()
        with tempfile.TemporaryDirectory() as temp_dir:
            result = service_loop(
                service.download_url(
                    source_url=(
                        "https://hitomi.la/reader/123456.html\n"
                        "https://ddd-smart.net/doujinshi3/show-m.php?g=20260411&dir=0058&page=0"
                    ),
                    destination_folder=temp_dir,
                    options=UrlDownloadOptions(),
                )
            )

        self.assertEqual(result.imported_count, 3)
        self.assertEqual(len(service.launcher_calls), 1)
        self.assertEqual(len(service.direct_calls), 1)

    def test_expands_hitomi_search_url_into_gallery_urls(self) -> None:
        service = _HitomiSearchRecordingUrlDownloadService()
        with tempfile.TemporaryDirectory() as temp_dir:
            result = service_loop(
                service.download_url(
                    source_url=(
                        "https://hitomi.la/search.html?"
                        "artist%3Achilt%20language%3Ajapanese%20type%3Adoujinshi"
                    ),
                    destination_folder=temp_dir,
                    options=UrlDownloadOptions(),
                )
            )

        self.assertEqual(result.imported_count, 2)
        self.assertEqual(len(service.launcher_calls), 1)
        self.assertEqual(len(service.direct_calls), 0)
        self.assertEqual(
            service.launcher_calls[0]["source_url"],
            "https://hitomi.la/galleries/300.html\n"
            "https://hitomi.la/galleries/200.html",
        )


def service_loop(awaitable):
    import asyncio

    return asyncio.run(awaitable)
