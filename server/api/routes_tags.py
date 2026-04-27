from __future__ import annotations

from fastapi import APIRouter, Depends, Request

from server.models.dto import (
    AddItemTagsRequest,
    AddItemTagsResponse,
    DeleteItemTagsRequest,
    FavoriteListResponse,
    FavoriteMediaListResponse,
    ItemTagsResponse,
    SetFavoriteRequest,
    TagListResponse,
)
from server.services.auth_service import require_bearer_token


router = APIRouter(tags=["tags"], dependencies=[Depends(require_bearer_token)])


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


@router.get("/tags/master", response_model=TagListResponse)
def list_tag_master(
    request: Request,
    category: str | None = None,
    contains: str | None = None,
    limit: int = 200,
) -> TagListResponse:
    items = request.app.state.metadata_store.list_tag_master(
        category=category,
        contains=contains,
        limit=max(1, min(limit, 1000)),
    )
    return TagListResponse(items=items)


@router.get("/tags/item/{media_id}", response_model=ItemTagsResponse)
@router.get("/items/{media_id}/tags", response_model=ItemTagsResponse)
def get_tags_for_item(request: Request, media_id: str) -> ItemTagsResponse:
    identity = _identity_from_query(request)
    resolved_media_id = request.app.state.metadata_store.resolve_media_id(
        media_id,
        identity=identity,
    )
    items = request.app.state.metadata_store.get_tags_for_media(
        media_id,
        identity=identity,
    )
    return ItemTagsResponse(mediaId=resolved_media_id, items=items)


@router.get("/favorites", response_model=FavoriteListResponse)
def list_favorites(request: Request) -> FavoriteListResponse:
    return FavoriteListResponse(
        items=request.app.state.metadata_store.list_favorite_media_ids()
    )


@router.get("/favorites/media", response_model=FavoriteMediaListResponse)
def list_favorite_media(request: Request) -> FavoriteMediaListResponse:
    return FavoriteMediaListResponse(
        items=request.app.state.metadata_store.list_favorite_media_items()
    )


@router.put("/favorites/{media_id}", response_model=AddItemTagsResponse)
def set_favorite(
    request: Request,
    media_id: str,
    payload: SetFavoriteRequest,
) -> AddItemTagsResponse:
    identity = payload.identity.model_dump(exclude_none=True) if payload.identity else None
    resolved_media_id = request.app.state.metadata_store.set_media_favorite(
        media_id,
        payload.isFavorite,
        identity=identity,
    )
    return AddItemTagsResponse(mediaId=resolved_media_id)


@router.delete("/tags/master/{tag_id}")
def delete_master_tag(request: Request, tag_id: str):
    deleted = request.app.state.metadata_store.delete_tag_master(tag_id)
    return {"ok": True, "message": f"deleted {deleted} tag(s)"}


@router.post("/tags/item/{media_id}", response_model=AddItemTagsResponse)
@router.post("/items/{media_id}/tags", response_model=AddItemTagsResponse)
def add_tags_to_item(
    request: Request,
    media_id: str,
    payload: AddItemTagsRequest,
) -> AddItemTagsResponse:
    tags = [entry.model_dump() for entry in payload.tags]
    if payload.tag is not None:
        tags.append(payload.tag.model_dump())
    identity = payload.identity.model_dump(exclude_none=True) if payload.identity else None
    resolved_media_id = request.app.state.metadata_store.add_tags_to_media(
        media_id,
        tags,
        identity=identity,
    )
    return AddItemTagsResponse(mediaId=resolved_media_id)


@router.put("/tags/item/{media_id}", response_model=AddItemTagsResponse)
@router.put("/items/{media_id}/tags", response_model=AddItemTagsResponse)
def replace_tags_for_item(
    request: Request,
    media_id: str,
    payload: AddItemTagsRequest,
) -> AddItemTagsResponse:
    tags = [entry.model_dump() for entry in payload.tags]
    if payload.tag is not None:
        tags.append(payload.tag.model_dump())
    identity = payload.identity.model_dump(exclude_none=True) if payload.identity else None
    resolved_media_id = request.app.state.metadata_store.replace_tags_for_media(
        media_id,
        tags,
        identity=identity,
    )
    return AddItemTagsResponse(mediaId=resolved_media_id)


@router.delete("/tags/item/{media_id}", response_model=AddItemTagsResponse)
def delete_tags_from_item(
    request: Request,
    media_id: str,
    payload: DeleteItemTagsRequest,
) -> AddItemTagsResponse:
    identity = _identity_from_query(request)
    resolved_media_id = request.app.state.metadata_store.remove_tags_from_media(
        media_id,
        payload.tagIds,
        identity=identity,
    )
    return AddItemTagsResponse(mediaId=resolved_media_id)


@router.delete("/tags/item/{media_id}/{tag_id}", response_model=AddItemTagsResponse)
@router.delete("/items/{media_id}/tags/{tag_id}", response_model=AddItemTagsResponse)
def delete_single_tag_from_item(
    request: Request,
    media_id: str,
    tag_id: str,
) -> AddItemTagsResponse:
    identity = _identity_from_query(request)
    resolved_media_id = request.app.state.metadata_store.remove_tags_from_media(
        media_id,
        [tag_id],
        identity=identity,
    )
    return AddItemTagsResponse(mediaId=resolved_media_id)
