from __future__ import annotations

import os

from fastapi import APIRouter, Depends, Request

from server.models.dto import FolderChildrenResponse, FolderListResponse, SearchResponse
from server.services.auth_service import require_bearer_token
from server.services.metadata_store import SearchQuery


router = APIRouter(tags=["search"], dependencies=[Depends(require_bearer_token)])


@router.get("/search", response_model=SearchResponse)
def search_media(
    request: Request,
    q: str | None = None,
    artist: str | None = None,
    series: str | None = None,
    character: str | None = None,
    mediaType: str | None = None,
    name: str | None = None,
    partial: bool = False,
    folderRaw: str | None = None,
    limit: int = 50,
    offset: int = 0,
) -> SearchResponse:
    safe_limit = max(1, min(limit, 1000))
    safe_offset = max(0, offset)
    items, total = request.app.state.metadata_store.search_media(
        SearchQuery(
            q=q,
            artist=artist,
            series=series,
            character=character,
            media_type=mediaType,
            name=name,
            partial=partial,
            folder_raw=folderRaw,
            limit=safe_limit,
            offset=safe_offset,
        )
    )
    return SearchResponse(items=items, total=total, limit=safe_limit, offset=safe_offset)


@router.get("/untagged", response_model=SearchResponse)
def list_untagged(
    request: Request,
    folderRaw: str | None = None,
    limit: int = 50,
    offset: int = 0,
) -> SearchResponse:
    safe_limit = max(1, min(limit, 1000))
    safe_offset = max(0, offset)
    items, total = request.app.state.metadata_store.list_untagged(
        folder_raw=folderRaw,
        limit=safe_limit,
        offset=safe_offset,
    )
    return SearchResponse(items=items, total=total, limit=safe_limit, offset=safe_offset)


@router.get("/folders", response_model=FolderListResponse)
def list_folders(request: Request) -> FolderListResponse:
    settings = request.app.state.settings
    indexed_items = request.app.state.metadata_store.list_indexed_folders()
    indexed_by_raw = {entry["folderRaw"]: entry for entry in indexed_items}

    items: list[dict[str, object | None]] = []
    for root in settings.media_roots:
        entry = indexed_by_raw.pop(root, None)
        if entry is None:
            items.append(
                {
                    "folderRaw": root,
                    "displayName": os.path.basename(os.path.normpath(root)) or root,
                    "lastScannedAt": None,
                }
            )
        else:
            items.append(entry)

    items.extend(indexed_by_raw.values())
    return FolderListResponse(items=items)


@router.get("/folders/children", response_model=FolderChildrenResponse)
@router.get("/items", response_model=FolderChildrenResponse)
def list_folder_children(
    request: Request,
    folderRaw: str,
    limit: int = 100,
    offset: int = 0,
) -> FolderChildrenResponse:
    safe_limit = max(1, min(limit, 1000))
    safe_offset = max(0, offset)
    items, total = request.app.state.metadata_store.list_folder_children(
        folderRaw,
        limit=safe_limit,
        offset=safe_offset,
    )
    return FolderChildrenResponse(
        items=items,
        total=total,
        limit=safe_limit,
        offset=safe_offset,
    )

