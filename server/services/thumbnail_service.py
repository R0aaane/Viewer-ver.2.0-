from __future__ import annotations

import io
import os
from pathlib import Path

import pypdfium2 as pdfium
from PIL import Image

from server.services.pillow_plugins import ensure_pillow_plugins

from server.core.errors import bad_request, not_found
from server.services.metadata_store import MetadataStore

ensure_pillow_plugins()


def _hash_key(source: str) -> str:
    value = 0x811C9DC5
    prime = 0x01000193
    for unit in source.encode("utf-8"):
        value ^= unit
        value = (value * prime) & 0xFFFFFFFF
    return f"{value:08x}"


class ThumbnailService:
    def __init__(self, metadata_store: MetadataStore, thumbs_dir: Path) -> None:
        self._metadata = metadata_store
        self._thumbs_dir = Path(thumbs_dir)
        self._thumbs_dir.mkdir(parents=True, exist_ok=True)

    def build_thumbnail(
        self,
        media_id: str,
        *,
        width: int | None = None,
        height: int | None = None,
        page: int | None = None,
    ) -> tuple[bytes, str]:
        record = self._metadata.get_media(media_id)
        if record["isDeleted"]:
            raise not_found("削除済みメディアです")

        path = record["fullPath"]
        if not os.path.exists(path):
            raise not_found("メディア本体が見つかりません")

        target_width = max(64, width or 360)
        target_height = max(64, height or 480)
        page_no = page or 1

        cache_key = _hash_key(
            f"thumb|{media_id}|{record['etag']}|{target_width}|{target_height}|{page_no}"
        )
        cache_path = self._thumbs_dir / f"{cache_key}.jpg"
        if cache_path.exists():
            return cache_path.read_bytes(), "image/jpeg"

        if record["kind"] == "pdf":
            image = self._render_pdf_page(path, page_no, target_width)
        else:
            image = Image.open(path).convert("RGB")
            image.thumbnail((target_width, target_height))

        with io.BytesIO() as output:
            image.save(output, format="JPEG", quality=85, optimize=True)
            data = output.getvalue()
        cache_path.write_bytes(data)
        return data, "image/jpeg"

    def render_pdf_page(
        self,
        media_id: str,
        *,
        page_no: int,
        width: int | None = None,
    ) -> tuple[bytes, str]:
        if page_no < 1:
            raise bad_request("pageNo は 1 以上で指定してください")

        record = self._metadata.get_media(media_id)
        if record["isDeleted"]:
            raise not_found("削除済みメディアです")
        if record["kind"] != "pdf":
            raise bad_request("PDF 以外では /page は利用できません")

        path = record["fullPath"]
        if not os.path.exists(path):
            raise not_found("PDF ファイルが見つかりません")

        target_width = max(128, width or 1600)
        image = self._render_pdf_page(path, page_no, target_width)
        with io.BytesIO() as output:
            image.save(output, format="PNG")
            return output.getvalue(), "image/png"

    def get_pdf_page_count(self, media_id: str) -> int:
        record = self._metadata.get_media(media_id)
        if record["isDeleted"]:
            raise not_found("削除済みメディアです")
        if record["kind"] != "pdf":
            raise bad_request("PDF 以外では pageCount を取得できません")

        path = record["fullPath"]
        if not os.path.exists(path):
            raise not_found("PDF ファイルが見つかりません")

        pdf = pdfium.PdfDocument(path)
        try:
            return len(pdf)
        finally:
            pdf.close()

    def _render_pdf_page(self, path: str, page_no: int, width: int) -> Image.Image:
        pdf = pdfium.PdfDocument(path)
        try:
            if page_no < 1 or page_no > len(pdf):
                raise bad_request("pageNo が範囲外です")
            page = pdf[page_no - 1]
            page_width, _ = page.get_size()
            scale = max(width / float(page_width), 0.2)
            rendered = page.render(scale=scale)
            try:
                pil_image = rendered.to_pil().convert("RGB")
            finally:
                rendered.close()
            return pil_image
        finally:
            pdf.close()
