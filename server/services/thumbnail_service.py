from __future__ import annotations

import io
import logging
import os
import tempfile
from dataclasses import dataclass
from pathlib import Path

import pypdfium2 as pdfium
from PIL import Image, ImageDraw

from server.core.errors import ApiError, bad_request, not_found
from server.core.media_formats import media_kind_for_extension, normalized_extension
from server.services.metadata_store import MetadataStore
from server.services.pillow_plugins import ensure_pillow_plugins

ensure_pillow_plugins()

logger = logging.getLogger(__name__)


def _hash_key(source: str) -> str:
    value = 0x811C9DC5
    prime = 0x01000193
    for unit in source.encode("utf-8"):
        value ^= unit
        value = (value * prime) & 0xFFFFFFFF
    return f"{value:08x}"


def _utf8_hex_preview(value: str, limit: int = 64) -> str:
    raw = str(value or "").encode("utf-8", errors="replace")
    preview = raw[:limit].hex()
    if len(raw) > limit:
        preview += "..."
    return preview


def _head_hex_preview(payload: bytes, limit: int = 16) -> str:
    preview = payload[:limit].hex()
    if len(payload) > limit:
        preview += "..."
    return preview


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
        refresh: bool = False,
    ) -> "ThumbnailBuildResult":
        record = self._metadata.get_media(media_id)
        self._log_media_resolution("build_thumbnail", media_id, record)
        if record["isDeleted"]:
            raise not_found("Media was not found")

        path = str(record["fullPath"])
        if not os.path.exists(path):
            raise not_found("Media file was not found")

        target_width = max(64, width or 360)
        target_height = max(64, height or 480)
        page_no = page or 1

        cache_key = _hash_key(
            f"thumb-v2|{media_id}|{record['etag']}|{target_width}|{target_height}|{page_no}"
        )
        cache_path = self._thumbs_dir / f"{cache_key}.jpg"
        if refresh:
            self._remove_cache_file(cache_path)
        if not refresh and cache_path.exists():
            try:
                return ThumbnailBuildResult(
                    payload=cache_path.read_bytes(),
                    mime="image/jpeg",
                    is_placeholder=False,
                )
            except OSError:
                logger.exception(
                    "[thumbnail][cache_read_failed] media_id=%s cache_path=%s",
                    media_id,
                    cache_path,
                )

        is_placeholder = False
        detail: str | None = None
        try:
            if _is_gif_collection_path(path):
                image = Image.open(_gif_collection_page_path(path, page_no)).convert("RGB")
                image.thumbnail((target_width, target_height))
            elif record["kind"] == "pdf":
                image, is_placeholder, detail = self._render_pdf_page(
                    media_id=media_id,
                    path=path,
                    page_no=page_no,
                    width=target_width,
                    height_hint=target_height,
                )
            else:
                image = Image.open(path).convert("RGB")
                image.thumbnail((target_width, target_height))
        except ApiError:
            raise
        except Exception:
            logger.exception(
                "[thumbnail][build_failed] media_id=%s path=%s kind=%s page=%s width=%s height=%s",
                media_id,
                path,
                record.get("kind"),
                page_no,
                target_width,
                target_height,
            )
            image = self._build_placeholder_image(
                target_width,
                target_height,
                "THUMB ERROR",
                detail=Path(path).suffix or str(record.get("kind") or "media"),
            )
            is_placeholder = True
            detail = "build_failed"

        with io.BytesIO() as output:
            image.save(output, format="JPEG", quality=85, optimize=True)
            data = output.getvalue()
        if is_placeholder:
            self._remove_cache_file(cache_path)
        else:
            self._write_bytes_atomic(cache_path, data)
        return ThumbnailBuildResult(
            payload=data,
            mime="image/jpeg",
            is_placeholder=is_placeholder,
            detail=detail,
        )

    def render_pdf_page(
        self,
        media_id: str,
        *,
        page_no: int,
        width: int | None = None,
    ) -> "ThumbnailBuildResult":
        if page_no < 1:
            raise bad_request("pageNo must be greater than or equal to 1")

        record = self._metadata.get_media(media_id)
        self._log_media_resolution("render_pdf_page", media_id, record)
        if record["isDeleted"]:
            raise not_found("Media was not found")
        if record["kind"] != "pdf":
            raise bad_request("/page is only available for PDF media")

        path = str(record["fullPath"])
        if not os.path.exists(path):
            raise not_found("PDF file was not found")

        if _is_gif_collection_path(path):
            page_path = _gif_collection_page_path(path, page_no)
            mime = "image/webp" if Path(page_path).suffix.lower() == ".webp" else "image/gif"
            return ThumbnailBuildResult(
                payload=Path(page_path).read_bytes(),
                mime=mime,
                is_placeholder=False,
            )

        target_width = max(128, width or 1600)
        is_placeholder = False
        detail: str | None = None
        try:
            image, is_placeholder, detail = self._render_pdf_page(
                media_id=media_id,
                path=path,
                page_no=page_no,
                width=target_width,
                height_hint=self._default_pdf_height(target_width),
            )
        except ApiError:
            raise
        except Exception:
            logger.exception(
                "[thumbnail][render_page_failed] media_id=%s path=%s page=%s width=%s",
                media_id,
                path,
                page_no,
                target_width,
            )
            image = self._build_placeholder_image(
                target_width,
                self._default_pdf_height(target_width),
                "PDF ERROR",
                detail=f"page {page_no}",
            )
            is_placeholder = True
            detail = f"page {page_no}"

        with io.BytesIO() as output:
            image.save(output, format="PNG")
            return ThumbnailBuildResult(
                payload=output.getvalue(),
                mime="image/png",
                is_placeholder=is_placeholder,
                detail=detail,
            )

    def get_pdf_page_count(self, media_id: str) -> int | None:
        try:
            record = self._metadata.get_media(media_id)
        except Exception:
            logger.exception(
                "[thumbnail][page_count_metadata_failed] media_id=%s",
                media_id,
            )
            return None

        self._log_media_resolution("get_pdf_page_count", media_id, record)
        if record.get("isDeleted") or record.get("kind") != "pdf":
            return None

        path = str(record["fullPath"])
        if _is_gif_collection_path(path):
            return len(_gif_collection_page_paths(path))

        self._log_pdf_probe(media_id, path, context="page_count")
        if not os.path.isfile(path):
            logger.warning(
                "[thumbnail][page_count_missing_file] media_id=%s path=%s",
                media_id,
                path,
            )
            return None

        pdf: pdfium.PdfDocument | None = None
        try:
            pdf = self._open_pdf_document(path)
            return len(pdf)
        except pdfium.PdfiumError:
            logger.exception(
                "[thumbnail][page_count_pdfium_error] media_id=%s path=%s",
                media_id,
                path,
            )
            return None
        except Exception:
            logger.exception(
                "[thumbnail][page_count_unexpected_error] media_id=%s path=%s",
                media_id,
                path,
            )
            return None
        finally:
            self._close_pdf(pdf, media_id=media_id, path=path, context="page_count")

    def _render_pdf_page(
        self,
        *,
        media_id: str,
        path: str,
        page_no: int,
        width: int,
        height_hint: int | None = None,
    ) -> tuple[Image.Image, bool, str | None]:
        self._log_pdf_probe(media_id, path, context="render_pdf_page")

        pdf: pdfium.PdfDocument | None = None
        page: pdfium.PdfPage | None = None
        rendered = None
        try:
            pdf = self._open_pdf_document(path)
            if page_no < 1 or page_no > len(pdf):
                raise bad_request("pageNo is out of range")
            page = pdf[page_no - 1]
            page_width, _ = page.get_size()
            scale = max(width / max(float(page_width), 1.0), 0.2)
            rendered = page.render(scale=scale)
            return rendered.to_pil().convert("RGB"), False, None
        except ApiError:
            raise
        except pdfium.PdfiumError:
            logger.exception(
                "[thumbnail][pdfium_error] media_id=%s path=%s page=%s width=%s",
                media_id,
                path,
                page_no,
                width,
            )
            detail = Path(path).suffix or "invalid pdf"
            return (
                self._build_placeholder_image(
                    width,
                    height_hint or self._default_pdf_height(width),
                    "PDF ERROR",
                    detail=detail,
                ),
                True,
                detail,
            )
        except Exception:
            logger.exception(
                "[thumbnail][render_pdf_page_unexpected_error] media_id=%s path=%s page=%s width=%s",
                media_id,
                path,
                page_no,
                width,
            )
            detail = "unexpected"
            return (
                self._build_placeholder_image(
                    width,
                    height_hint or self._default_pdf_height(width),
                    "PDF ERROR",
                    detail=detail,
                ),
                True,
                detail,
            )
        finally:
            if rendered is not None:
                try:
                    rendered.close()
                except Exception:
                    logger.warning(
                        "[thumbnail][render_close_failed] media_id=%s path=%s",
                        media_id,
                        path,
                        exc_info=True,
                    )
            if page is not None:
                try:
                    page.close()
                except Exception:
                    logger.warning(
                        "[thumbnail][page_close_failed] media_id=%s path=%s page=%s",
                        media_id,
                        path,
                        page_no,
                        exc_info=True,
                    )
            self._close_pdf(pdf, media_id=media_id, path=path, context="render_pdf_page")

    def _log_media_resolution(
        self,
        context: str,
        media_id: str,
        record: dict[str, object],
    ) -> None:
        path = str(record.get("fullPath") or "")
        kind = str(record.get("kind") or "")
        extension = normalized_extension(path)
        expected_kind = media_kind_for_extension(extension)
        exists = os.path.exists(path)
        is_file = os.path.isfile(path)
        size_bytes = self._safe_file_size(path)
        logger.info(
            "[thumbnail][%s] media_id=%s path=%s path_repr=%r path_utf8=%s kind=%s extension=%s expected_kind=%s kind_matches=%s exists=%s is_file=%s size=%s",
            context,
            media_id,
            path,
            path,
            _utf8_hex_preview(path),
            kind,
            extension,
            expected_kind,
            expected_kind == kind if expected_kind else False,
            exists,
            is_file,
            size_bytes,
        )

    def _open_pdf_document(self, path: str) -> pdfium.PdfDocument:
        handle = open(path, "rb")
        try:
            return pdfium.PdfDocument(handle, autoclose=True)
        except Exception:
            handle.close()
            raise

    def _log_pdf_probe(self, media_id: str, path: str, *, context: str) -> None:
        exists = os.path.exists(path)
        is_file = os.path.isfile(path)
        size_bytes = self._safe_file_size(path)
        head_preview = self._safe_file_head(path)
        logger.info(
            "[thumbnail][%s] media_id=%s path=%s path_repr=%r path_utf8=%s exists=%s is_file=%s size=%s head16=%s",
            context,
            media_id,
            path,
            path,
            _utf8_hex_preview(path),
            exists,
            is_file,
            size_bytes,
            head_preview,
        )

    def _safe_file_size(self, path: str) -> int | None:
        try:
            return os.path.getsize(path)
        except OSError:
            logger.warning(
                "[thumbnail][file_size_failed] path=%s path_repr=%r path_utf8=%s",
                path,
                path,
                _utf8_hex_preview(path),
                exc_info=True,
            )
            return None

    def _safe_file_head(self, path: str) -> str:
        if not os.path.isfile(path):
            return "<missing>"
        try:
            with open(path, "rb") as handle:
                return _head_hex_preview(handle.read(16), limit=16)
        except OSError:
            logger.warning(
                "[thumbnail][file_head_failed] path=%s path_repr=%r path_utf8=%s",
                path,
                path,
                _utf8_hex_preview(path),
                exc_info=True,
            )
            return "<read-error>"

    def _build_placeholder_image(
        self,
        width: int,
        height: int,
        label: str,
        *,
        detail: str | None = None,
    ) -> Image.Image:
        safe_width = max(64, int(width or 64))
        safe_height = max(64, int(height or 64))
        image = Image.new("RGB", (safe_width, safe_height), color=(30, 34, 40))
        draw = ImageDraw.Draw(image)
        draw.rectangle(
            (0, 0, safe_width - 1, safe_height - 1),
            outline=(176, 88, 88),
            width=3,
        )
        draw.line((0, 0, safe_width - 1, safe_height - 1), fill=(176, 88, 88), width=2)
        draw.line((safe_width - 1, 0, 0, safe_height - 1), fill=(176, 88, 88), width=2)
        draw.text((12, 12), label[:32], fill=(255, 236, 236))
        if detail:
            draw.text((12, 34), detail[:48], fill=(220, 220, 220))
        return image

    def _default_pdf_height(self, width: int) -> int:
        return max(96, int(width * 1.414))

    def _write_bytes_atomic(self, destination: Path, payload: bytes) -> None:
        destination.parent.mkdir(parents=True, exist_ok=True)
        temp_path: str | None = None
        try:
            with tempfile.NamedTemporaryFile(
                mode="wb",
                delete=False,
                dir=str(destination.parent),
                prefix=f".{destination.name}.",
                suffix=".tmp",
            ) as handle:
                temp_path = handle.name
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temp_path, destination)
        except Exception:
            logger.warning(
                "[thumbnail][cache_write_failed] destination=%s temp_path=%s",
                destination,
                temp_path,
                exc_info=True,
            )
            if temp_path:
                try:
                    os.remove(temp_path)
                except OSError:
                    logger.warning(
                        "[thumbnail][cache_cleanup_failed] temp_path=%s",
                        temp_path,
                        exc_info=True,
                    )

    def _remove_cache_file(self, path: Path) -> None:
        try:
            if path.exists():
                path.unlink()
        except OSError:
            logger.warning(
                "[thumbnail][cache_remove_failed] path=%s",
                path,
                exc_info=True,
            )

    def _close_pdf(
        self,
        pdf: pdfium.PdfDocument | None,
        *,
        media_id: str,
        path: str,
        context: str,
    ) -> None:
        if pdf is None:
            return
        try:
            pdf.close()
        except Exception:
            logger.warning(
                "[thumbnail][pdf_close_failed] context=%s media_id=%s path=%s",
                context,
                media_id,
                path,
                exc_info=True,
            )


@dataclass(frozen=True)
class ThumbnailBuildResult:
    payload: bytes
    mime: str
    is_placeholder: bool = False
    detail: str | None = None


def _is_gif_collection_path(path: str) -> bool:
    return os.path.isdir(path) and bool(_gif_collection_page_paths(path))


def _is_animated_webp(path: str) -> bool:
    if Path(path).suffix.lower() != ".webp":
        return False
    try:
        with Image.open(path) as image:
            return bool(getattr(image, "is_animated", False)) or int(
                getattr(image, "n_frames", 1) or 1
            ) > 1
    except OSError:
        return False


def _is_gif_collection_member(path: str) -> bool:
    ext = Path(path).suffix.lower()
    if ext == ".gif":
        return True
    return ext == ".webp" and _is_animated_webp(path)


def _gif_collection_page_paths(path: str) -> list[str]:
    if not os.path.isdir(path):
        return []
    return [
        os.path.join(path, file_name)
        for file_name in sorted(os.listdir(path), key=lambda value: value.casefold())
        if _is_gif_collection_member(os.path.join(path, file_name))
        and os.path.isfile(os.path.join(path, file_name))
    ]


def _gif_collection_page_path(path: str, page_no: int) -> str:
    pages = _gif_collection_page_paths(path)
    if page_no < 1 or page_no > len(pages):
        raise bad_request("pageNo is out of range")
    return pages[page_no - 1]
