from __future__ import annotations

from pathlib import Path


SUPPORTED_IMAGE_EXTENSIONS = frozenset({".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".avif"})
SUPPORTED_MEDIA_EXTENSIONS = frozenset({*SUPPORTED_IMAGE_EXTENSIONS, ".pdf"})


def normalized_extension(file_name: str) -> str:
    return Path(file_name).suffix.lower()


def is_supported_image_extension(extension: str) -> bool:
    return extension.lower() in SUPPORTED_IMAGE_EXTENSIONS


def is_supported_media_extension(extension: str) -> bool:
    return extension.lower() in SUPPORTED_MEDIA_EXTENSIONS


def media_kind_for_extension(extension: str) -> str | None:
    normalized = extension.lower()
    if normalized == ".pdf":
        return "pdf"
    if normalized in SUPPORTED_IMAGE_EXTENSIONS:
        return "image"
    return None
