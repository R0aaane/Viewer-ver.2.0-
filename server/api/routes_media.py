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
)
from server.services.auth_service import require_bearer_token


router = APIRouter(tags=["media"], dependencies=[Depends(require_bearer_token)])
logger = logging.getLogger(__name__)


@router.get("/media/{media_id}/meta", response_model=MediaMetaResponse)
@router.get("/items/{media_id}", response_model=MediaMetaResponse)
def get_media_meta(request: Request, media_id: str) -> MediaMetaResponse:
    meta = request.app.state.stream_service.get_media_meta(media_id)
    meta["stats"] = None
    if meta["kind"] == "pdf":
        meta["stats"] = request.app.state.metadata_store.get_media_stats(media_id)
        try:
            meta["pageCount"] = request.app.state.thumbnail_service.get_pdf_page_count(
                media_id
            )
        except Exception:
            logger.exception("[media][meta_page_count_failed] media_id=%s", media_id)
            meta["pageCount"] = None
    return MediaMetaResponse(**meta)


@router.post("/media/{media_id}/view", response_model=MediaStatsDto)
@router.post("/items/{media_id}/view", response_model=MediaStatsDto)
def record_media_view(request: Request, media_id: str) -> MediaStatsDto:
    stats = request.app.state.metadata_store.record_media_view(media_id)
    return MediaStatsDto(**stats)


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
) -> Response:
    result = request.app.state.thumbnail_service.render_pdf_page(
        media_id,
        page_no=page_no,
        width=width,
    )
    headers = {
        "X-Thumbnail-Status": "placeholder" if result.is_placeholder else "ok",
    }
    if result.detail:
        headers["X-Thumbnail-Detail"] = result.detail
    return Response(content=result.payload, media_type=result.mime, headers=headers)
