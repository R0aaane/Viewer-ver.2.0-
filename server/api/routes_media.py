from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, Request
from fastapi.responses import Response

from server.models.dto import (
    MediaActivityDto,
    MediaActivityListResponse,
    MediaMetaResponse,
    MediaStatsDto,
    RecordMediaActivityRequest,
    ReadingProgressDto,
    ReadingProgressListResponse,
    UpdateReadingProgressRequest,
)
from server.services.auth_service import require_bearer_token


router = APIRouter(tags=["media"], dependencies=[Depends(require_bearer_token)])
logger = logging.getLogger(__name__)


def _identity_from_query(request: Request) -> dict[str, object] | None:
    aliases = [
        value.strip()
        for key, value in sorted(request.query_params.items())
        if key.startswith("alias") and value.strip()
    ]

    size_bytes_raw = request.query_params.get("sizeBytes")
    modified_epoch_ms_raw = request.query_params.get("modifiedEpochMs")
    identity: dict[str, object] = {
        "aliases": aliases,
    }

    normalized_path = request.query_params.get("normalizedPath")
    if normalized_path:
        identity["normalizedPath"] = normalized_path

    relative_path_hint = request.query_params.get("relativePathHint")
    if relative_path_hint:
        identity["relativePathHint"] = relative_path_hint

    if size_bytes_raw:
        try:
            identity["sizeBytes"] = int(size_bytes_raw)
        except ValueError:
            pass

    if modified_epoch_ms_raw:
        try:
            identity["modifiedEpochMs"] = int(modified_epoch_ms_raw)
        except ValueError:
            pass

    return identity if any(identity.values()) else None


@router.get("/media/{media_id}/meta", response_model=MediaMetaResponse)
@router.get("/items/{media_id}", response_model=MediaMetaResponse)
def get_media_meta(request: Request, media_id: str) -> MediaMetaResponse:
    identity = _identity_from_query(request)
    resolved_media_id = request.app.state.metadata_store.resolve_media_id(
        media_id,
        identity=identity,
    )
    meta = request.app.state.stream_service.get_media_meta(resolved_media_id)
    meta["stats"] = None
    if meta["kind"] == "pdf":
        meta["stats"] = request.app.state.metadata_store.get_media_stats(
            resolved_media_id,
            identity=identity,
        )
        try:
            meta["pageCount"] = request.app.state.thumbnail_service.get_pdf_page_count(
                resolved_media_id
            )
        except Exception:
            logger.exception(
                "[media][meta_page_count_failed] media_id=%s",
                resolved_media_id,
            )
            meta["pageCount"] = None
    return MediaMetaResponse(**meta)


@router.post("/media/{media_id}/view", response_model=MediaStatsDto)
@router.post("/items/{media_id}/view", response_model=MediaStatsDto)
def record_media_view(request: Request, media_id: str) -> MediaStatsDto:
    identity = _identity_from_query(request)
    stats = request.app.state.metadata_store.record_media_view(
        media_id,
        identity=identity,
    )
    return MediaStatsDto(**stats)


@router.get("/progress/recent", response_model=ReadingProgressListResponse)
def list_recent_reading_progress(
    request: Request,
    limit: int = 24,
) -> ReadingProgressListResponse:
    items = request.app.state.metadata_store.list_recent_reading_progress(limit=limit)
    return ReadingProgressListResponse(items=items)


@router.get("/progress/{media_id}", response_model=ReadingProgressDto)
def get_reading_progress(request: Request, media_id: str) -> ReadingProgressDto:
    identity = _identity_from_query(request)
    item = request.app.state.metadata_store.get_reading_progress(
        media_id,
        identity=identity,
    )
    return ReadingProgressDto(**item)


@router.put("/progress/{media_id}", response_model=ReadingProgressDto)
def update_reading_progress(
    request: Request,
    media_id: str,
    payload: UpdateReadingProgressRequest,
) -> ReadingProgressDto:
    identity = payload.identity.model_dump(exclude_none=True) if payload.identity else None
    item = request.app.state.metadata_store.upsert_reading_progress(
        media_id,
        identity=identity,
        current_page=payload.currentPage,
        total_pages=payload.totalPages,
        progress=payload.progress,
        last_read_at=payload.lastReadAt,
        updated_at=payload.updatedAt,
        is_bookmarked=payload.isBookmarked,
    )
    return ReadingProgressDto(**item)


@router.get("/activity/recent", response_model=MediaActivityListResponse)
def list_recent_media_activity(
    request: Request,
    limit: int = 24,
) -> MediaActivityListResponse:
    items = request.app.state.metadata_store.list_recent_media_activity(limit=limit)
    return MediaActivityListResponse(items=items)


@router.post("/media/{media_id}/activity", response_model=MediaActivityDto)
@router.post("/items/{media_id}/activity", response_model=MediaActivityDto)
def record_media_activity(
    request: Request,
    media_id: str,
    payload: RecordMediaActivityRequest,
) -> MediaActivityDto:
    identity = payload.identity.model_dump(exclude_none=True) if payload.identity else None
    item = request.app.state.metadata_store.record_media_activity(
        media_id,
        identity=identity,
        last_page=payload.lastPage,
        total_pages=payload.totalPages,
    )
    return MediaActivityDto(**item)


@router.get("/media/{media_id}/download")
@router.get("/items/{media_id}/download")
def download_media(request: Request, media_id: str) -> Response:
    return request.app.state.stream_service.build_download_response(media_id, request)


@router.get("/media/{media_id}/thumb")
@router.get("/items/{media_id}/thumb")
def get_thumbnail(
    request: Request,
    media_id: str,
    width: int | None = None,
    height: int | None = None,
    page: int | None = None,
    refresh: str | None = None,
) -> Response:
    result = request.app.state.thumbnail_service.build_thumbnail(
        media_id,
        width=width,
        height=height,
        page=page,
        refresh=bool(refresh and refresh.strip()),
    )
    headers = {
        "X-Thumbnail-Status": "placeholder" if result.is_placeholder else "ok",
    }
    if result.detail:
        headers["X-Thumbnail-Detail"] = result.detail
    return Response(content=result.payload, media_type=result.mime, headers=headers)


@router.get("/media/{media_id}/page/{page_no}")
def render_pdf_page(
    request: Request,
    media_id: str,
    page_no: int,
    width: int | None = None,
    format: str | None = None,
) -> Response:
    result = request.app.state.thumbnail_service.render_pdf_page(
        media_id,
        page_no=page_no,
        width=width,
        image_format=format,
    )
    headers = {
        "X-Thumbnail-Status": "placeholder" if result.is_placeholder else "ok",
    }
    if result.detail:
        headers["X-Thumbnail-Detail"] = result.detail
    return Response(content=result.payload, media_type=result.mime, headers=headers)
