from __future__ import annotations

import os
from datetime import datetime, timezone
from email.utils import format_datetime
from typing import Iterator

from fastapi import Request
from fastapi.responses import Response, StreamingResponse

from server.core.config import Settings
from server.core.errors import bad_request, not_found
from server.services.metadata_store import MetadataStore


class MediaStreamService:
    def __init__(self, metadata_store: MetadataStore, settings: Settings) -> None:
        self._metadata = metadata_store
        self._settings = settings

    def get_media_meta(self, media_id: str) -> dict[str, object]:
        record = self._metadata.get_media(media_id)
        if record["isDeleted"]:
            raise not_found("削除済みメディアです")
        return {
            "mediaId": record["mediaId"],
            "displayName": record["displayName"],
            "kind": record["kind"],
            "mimeType": record["mimeType"],
            "sizeBytes": record["sizeBytes"],
            "modifiedAt": record["modifiedAt"],
            "etag": record["etag"],
            "supportsRange": not os.path.isdir(str(record["fullPath"])),
        }

    def build_download_response(self, media_id: str, request: Request) -> Response:
        record = self._metadata.get_media(media_id)
        if record["isDeleted"]:
            raise not_found("削除済みメディアです")

        full_path = record["fullPath"]
        if os.path.isdir(full_path):
            raise bad_request("GIF collection download is not supported")
        if not os.path.exists(full_path):
            raise not_found("メディア本体が見つかりません")

        file_size = os.path.getsize(full_path)
        etag = record["etag"] or ""
        modified = record["modifiedAt"]
        headers = {
            "ETag": etag,
            "Accept-Ranges": "bytes",
            "Last-Modified": format_datetime(
                modified.astimezone(timezone.utc) if isinstance(modified, datetime) else datetime.now(timezone.utc),
                usegmt=True,
            ),
        }

        range_header = request.headers.get("range")
        if not range_header:
            headers["Content-Length"] = str(file_size)
            return StreamingResponse(
                self._iter_file(full_path),
                media_type=record["mimeType"] or "application/octet-stream",
                headers=headers,
            )

        start, end = self._parse_range(range_header, file_size)
        length = end - start + 1
        headers["Content-Range"] = f"bytes {start}-{end}/{file_size}"
        headers["Content-Length"] = str(length)
        return StreamingResponse(
            self._iter_file(full_path, start=start, length=length),
            media_type=record["mimeType"] or "application/octet-stream",
            status_code=206,
            headers=headers,
        )

    def _iter_file(
        self,
        path: str,
        *,
        start: int = 0,
        length: int | None = None,
    ) -> Iterator[bytes]:
        remaining = length
        with open(path, "rb") as handle:
            handle.seek(start)
            while True:
                chunk_size = self._settings.stream_chunk_size
                if remaining is not None:
                    if remaining <= 0:
                        break
                    chunk_size = min(chunk_size, remaining)
                chunk = handle.read(chunk_size)
                if not chunk:
                    break
                if remaining is not None:
                    remaining -= len(chunk)
                yield chunk

    def _parse_range(self, header: str, file_size: int) -> tuple[int, int]:
        if not header.startswith("bytes="):
            raise bad_request("Range ヘッダーの形式が不正です")

        raw = header[len("bytes=") :].strip()
        if "," in raw:
            raise bad_request("複数 Range は未対応です")

        start_raw, _, end_raw = raw.partition("-")
        if not start_raw and not end_raw:
            raise bad_request("Range ヘッダーの形式が不正です")

        if not start_raw:
            suffix = int(end_raw)
            if suffix <= 0:
                raise bad_request("Range ヘッダーの形式が不正です")
            start = max(file_size - suffix, 0)
            end = file_size - 1
            return start, end

        start = int(start_raw)
        end = int(end_raw) if end_raw else file_size - 1
        if start < 0 or end < start or start >= file_size:
            raise bad_request("Range ヘッダーの範囲が不正です")
        return start, min(end, file_size - 1)
