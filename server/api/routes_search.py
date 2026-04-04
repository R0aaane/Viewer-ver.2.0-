from __future__ import annotations

import os

from fastapi import APIRouter, Depends, Request

from server.models.dto import FolderChildrenResponse, FolderListResponse, SearchResponse
from server.services.auth_service import require_bearer_token
from server.services.metadata_store import SearchQuery


router = APIRouter(tags=["search"], dependencies=[Depends(require_bearer_token)])


def _normalize_path(raw: str) -> str:
    return os.path.normpath(raw).replace('/', '\\').casefold()


def _configured_media_roots(request: Request) -> list[str]:
    roots: list[str] = []
    seen: set[str] = set()
    for root in request.app.state.settings.media_roots:
        normalized_root = _normalize_path(root)
        if not normalized_root or normalized_root in seen:
            continue
        seen.add(normalized_root)
        roots.append(os.path.normpath(root))
    return roots


def _is_allowed_folder(folder_raw: str | None, roots: list[str]) -> bool:
    if folder_raw is None:
        return True

    normalized_folder = _normalize_path(folder_raw)
    for root in roots:
        normalized_root = _normalize_path(root)
        if normalized_folder == normalized_root:
            return True
        if normalized_folder.startswith(f"{normalized_root}\\"):
            return True
    return False


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
    roots = _configured_media_roots(request)
    if not _is_allowed_folder(folderRaw, roots):
        return SearchResponse(items=[], total=0, limit=safe_limit, offset=safe_offset)
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
    roots = _configured_media_roots(request)
    if not _is_allowed_folder(folderRaw, roots):
        return SearchResponse(items=[], total=0, limit=safe_limit, offset=safe_offset)
    items, total = request.app.state.metadata_store.list_untagged(
        folder_raw=folderRaw,
        limit=safe_limit,
        offset=safe_offset,
    )
    return SearchResponse(items=items, total=total, limit=safe_limit, offset=safe_offset)


@router.get("/folders", response_model=FolderListResponse)
def list_folders(request: Request) -> FolderListResponse:
    indexed_items = request.app.state.metadata_store.list_indexed_folders()
    indexed_by_raw = {
        _normalize_path(str(entry["folderRaw"])): entry for entry in indexed_items
    }

    items: list[dict[str, object | None]] = []
    for root in _configured_media_roots(request):
        entry = indexed_by_raw.get(_normalize_path(root))
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
    roots = _configured_media_roots(request)
    if not _is_allowed_folder(folderRaw, roots):
        return FolderChildrenResponse(
            items=[],
            total=0,
            limit=safe_limit,
            offset=safe_offset,
        )
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
