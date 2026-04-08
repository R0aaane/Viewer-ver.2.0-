from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import pypdfium2 as pdfium

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
                payload, mime = service.build_thumbnail(
                    "mid:broken.pdf",
                    width=240,
                    height=320,
                    page=1,
                )

        self.assertEqual(mime, "image/jpeg")
        self.assertTrue(payload.startswith(b"\xff\xd8"))
        self.assertGreater(len(payload), 0)

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
                payload, mime = service.render_pdf_page(
                    "mid:broken.pdf",
                    page_no=1,
                    width=800,
                )

        self.assertEqual(mime, "image/png")
        self.assertTrue(payload.startswith(b"\x89PNG\r\n\x1a\n"))
        self.assertGreater(len(payload), 0)

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
