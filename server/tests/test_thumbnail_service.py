from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import pypdfium2 as pdfium
from PIL import Image

from server.services.thumbnail_service import ThumbnailService


class _FakeMetadataStore:
    def __init__(self, record: dict[str, object]) -> None:
        self._record = record

    def get_media(self, media_id: str) -> dict[str, object]:
        if media_id != self._record["mediaId"]:
            raise KeyError(media_id)
        return dict(self._record)


class ThumbnailServiceTest(unittest.TestCase):
    def _record_for(self, pdf_path: Path) -> dict[str, object]:
        return {
            "mediaId": "mid:broken.pdf",
            "displayName": pdf_path.name,
            "folderRaw": str(pdf_path.parent),
            "kind": "pdf",
            "fullPath": str(pdf_path),
            "sizeBytes": pdf_path.stat().st_size,
            "modifiedAt": None,
            "mimeType": "application/pdf",
            "etag": "etag-broken",
            "isDeleted": False,
        }

    def test_build_thumbnail_returns_placeholder_for_pdfium_error(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            pdf_path = Path(temp_dir) / "broken.pdf"
            pdf_path.write_bytes(b"not-a-real-pdf")
            service = ThumbnailService(
                _FakeMetadataStore(self._record_for(pdf_path)),
                Path(temp_dir) / "thumbs",
            )

            with patch(
                "server.services.thumbnail_service.pdfium.PdfDocument",
                side_effect=pdfium.PdfiumError("Data format error"),
            ):
                result = service.build_thumbnail(
                    "mid:broken.pdf",
                    width=240,
                    height=320,
                    page=1,
                )

        self.assertEqual(result.mime, "image/jpeg")
        self.assertTrue(result.payload.startswith(b"\xff\xd8"))
        self.assertGreater(len(result.payload), 0)
        self.assertTrue(result.is_placeholder)

    def test_render_pdf_page_returns_placeholder_for_pdfium_error(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            pdf_path = Path(temp_dir) / "broken.pdf"
            pdf_path.write_bytes(b"still-not-a-real-pdf")
            service = ThumbnailService(
                _FakeMetadataStore(self._record_for(pdf_path)),
                Path(temp_dir) / "thumbs",
            )

            with patch(
                "server.services.thumbnail_service.pdfium.PdfDocument",
                side_effect=pdfium.PdfiumError("Data format error"),
            ):
                result = service.render_pdf_page(
                    "mid:broken.pdf",
                    page_no=1,
                    width=800,
                    image_format="jpg",
                )

        self.assertEqual(result.mime, "image/jpeg")
        self.assertTrue(result.payload.startswith(b"\xff\xd8"))
        self.assertGreater(len(result.payload), 0)
        self.assertTrue(result.is_placeholder)

    def test_render_pdf_page_reuses_cached_page_image(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            pdf_path = Path(temp_dir) / "sample.pdf"
            pdf_path.write_bytes(b"%PDF-1.7\n")
            service = ThumbnailService(
                _FakeMetadataStore(self._record_for(pdf_path)),
                Path(temp_dir) / "thumbs",
            )

            with patch.object(
                service,
                "_render_pdf_page",
                return_value=(Image.new("RGB", (32, 48), "white"), False, None),
            ) as render_mock:
                first = service.render_pdf_page(
                    "mid:broken.pdf",
                    page_no=1,
                    width=320,
                    image_format="jpg",
                )
                second = service.render_pdf_page(
                    "mid:broken.pdf",
                    page_no=1,
                    width=320,
                    image_format="jpg",
                )

        self.assertEqual(first.mime, "image/jpeg")
        self.assertEqual(second.mime, "image/jpeg")
        self.assertEqual(first.payload, second.payload)
        self.assertEqual(render_mock.call_count, 1)

    def test_get_pdf_page_count_returns_none_for_pdfium_error(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            pdf_path = Path(temp_dir) / "broken.pdf"
            pdf_path.write_bytes(b"broken")
            service = ThumbnailService(
                _FakeMetadataStore(self._record_for(pdf_path)),
                Path(temp_dir) / "thumbs",
            )

            with patch(
                "server.services.thumbnail_service.pdfium.PdfDocument",
                side_effect=pdfium.PdfiumError("Data format error"),
            ):
                page_count = service.get_pdf_page_count("mid:broken.pdf")

        self.assertIsNone(page_count)


if __name__ == "__main__":
    unittest.main()
