from __future__ import annotations

from fastapi import APIRouter, Depends, Request
from fastapi.responses import Response

from server.models.dto import MediaMetaResponse
from server.services.auth_service import require_bearer_token


router = APIRouter(tags=["media"], dependencies=[Depends(require_bearer_token)])


@router.get("/media/{media_id}/meta", response_model=MediaMetaResponse)
@router.get("/items/{media_id}", response_model=MediaMetaResponse)
def get_media_meta(request: Request, media_id: str) -> MediaMetaResponse:
    meta = request.app.state.stream_service.get_media_meta(media_id)
    if meta["kind"] == "pdf":
        meta["pageCount"] = request.app.state.thumbnail_service.get_pdf_page_count(
            media_id
        )
    return MediaMetaResponse(**meta)


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
) -> Response:
    payload, mime = request.app.state.thumbnail_service.build_thumbnail(
        media_id,
        width=width,
        height=height,
        page=page,
    )
    return Response(content=payload, media_type=mime)


@router.get("/media/{media_id}/page/{page_no}")
def render_pdf_page(
    request: Request,
    media_id: str,
    page_no: int,
    width: int | None = None,
) -> Response:
    payload, mime = request.app.state.thumbnail_service.render_pdf_page(
        media_id,
        page_no=page_no,
        width=width,
    )
    return Response(content=payload, media_type=mime)
