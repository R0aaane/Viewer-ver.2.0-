from __future__ import annotations

from fastapi import APIRouter, Depends, Request

from server.models.dto import (
    AddItemTagsRequest,
    AddItemTagsResponse,
    DeleteItemTagsRequest,
    ItemTagsResponse,
    TagListResponse,
)
from server.services.auth_service import require_bearer_token


router = APIRouter(tags=["tags"], dependencies=[Depends(require_bearer_token)])


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
    items = request.app.state.metadata_store.get_tags_for_media(media_id)
    return ItemTagsResponse(mediaId=media_id, items=items)


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
    request.app.state.metadata_store.add_tags_to_media(media_id, tags)
    return AddItemTagsResponse(mediaId=media_id)


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
    request.app.state.metadata_store.replace_tags_for_media(media_id, tags)
    return AddItemTagsResponse(mediaId=media_id)


@router.delete("/tags/item/{media_id}", response_model=AddItemTagsResponse)
def delete_tags_from_item(
    request: Request,
    media_id: str,
    payload: DeleteItemTagsRequest,
) -> AddItemTagsResponse:
    request.app.state.metadata_store.remove_tags_from_media(media_id, payload.tagIds)
    return AddItemTagsResponse(mediaId=media_id)


@router.delete("/tags/item/{media_id}/{tag_id}", response_model=AddItemTagsResponse)
@router.delete("/items/{media_id}/tags/{tag_id}", response_model=AddItemTagsResponse)
def delete_single_tag_from_item(
    request: Request,
    media_id: str,
    tag_id: str,
) -> AddItemTagsResponse:
    request.app.state.metadata_store.remove_tags_from_media(media_id, [tag_id])
    return AddItemTagsResponse(mediaId=media_id)
