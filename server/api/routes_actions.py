from __future__ import annotations

import os
from pathlib import Path

from fastapi import APIRouter, Depends, File, Form, Request, UploadFile

from server.core.errors import bad_request
from server.models.dto import DeleteRequest, MessageResponse, RenameRequest, RescanRequest
from server.services.auth_service import require_bearer_token


router = APIRouter(tags=["actions"], dependencies=[Depends(require_bearer_token)])


@router.post("/rescan", response_model=MessageResponse)
def request_rescan(
    request: Request,
    payload: RescanRequest | None = None,
) -> MessageResponse:
    index_service = request.app.state.index_service
    settings = request.app.state.settings

    target = payload.folderRaw if payload else None
    if target:
        scanned = index_service.scan_folder(target)
        return MessageResponse(message=f"再スキャン要求を受け付けました: {scanned} 件を更新")

    results = index_service.rescan_configured_roots(settings.media_roots)
    total = sum(int(entry["count"]) for entry in results)
    return MessageResponse(message=f"再スキャン要求を受け付けました: {total} 件を更新")


@router.post("/upload")
async def upload_files(
    request: Request,
    folderRaw: str = Form(...),
    skipIfExists: bool = Form(True),
    files: list[UploadFile] = File(...),
) -> dict[str, object]:
    if not files:
        raise bad_request("アップロードするファイルがありません")

    settings = request.app.state.settings
    folder_path = os.path.normpath(folderRaw)
    if not os.path.isdir(folder_path):
        raise bad_request(f"保存先フォルダが存在しません: {folderRaw}")
    if settings.media_roots and not any(_is_inside_root(folder_path, root) for root in settings.media_roots):
        raise bad_request("保存先フォルダが共有対象に含まれていません")

    imported_count = 0
    skipped_count = 0

    for upload in files:
        file_name = (upload.filename or "").strip()
        if not file_name:
            skipped_count += 1
            continue

        destination = os.path.join(folder_path, file_name)
        if os.path.exists(destination):
            if skipIfExists:
                skipped_count += 1
                continue
            destination = _unique_path(folder_path, file_name)

        try:
            with open(destination, "wb") as handle:
                while True:
                    chunk = await upload.read(1024 * 1024)
                    if not chunk:
                        break
                    handle.write(chunk)
            imported_count += 1
        finally:
            await upload.close()

    request.app.state.index_service.scan_folder(folder_path)
    return {
        "ok": True,
        "importedCount": imported_count,
        "skippedCount": skipped_count,
    }


@router.post("/rename", response_model=MessageResponse)
def apply_rename(request: Request, payload: RenameRequest) -> MessageResponse:
    before = payload.before
    after = payload.after
    request.app.state.metadata_store.apply_rename(
        old_media_id=payload.oldMediaId or (before.mediaId if before else None),
        new_media_id=payload.newMediaId or (after.mediaId if after else None),
        old_path=payload.oldPath or (before.path if before else None),
        new_path=payload.newPath or (after.path if after else None),
    )
    return MessageResponse(message="リネームを反映しました")


@router.post("/delete", response_model=MessageResponse)
def apply_delete(request: Request, payload: DeleteRequest) -> MessageResponse:
    items = [entry.model_dump() for entry in payload.items]
    if not items:
        items = [
            {
                "mediaId": payload.mediaId,
                "path": payload.path,
                "folderRaw": payload.folderRaw,
                "displayName": payload.displayName,
                "hardDelete": payload.hardDelete,
            }
        ]
    deleted = request.app.state.metadata_store.apply_delete(
        items=items,
        hard_delete=payload.hardDelete,
    )
    return MessageResponse(message=f"削除を反映しました ({deleted} 件)")


def _is_inside_root(folder_path: str, root: str) -> bool:
    normalized_folder = os.path.normcase(os.path.normpath(folder_path))
    normalized_root = os.path.normcase(os.path.normpath(root))
    return normalized_folder == normalized_root or normalized_folder.startswith(normalized_root + os.sep)


def _unique_path(folder_path: str, file_name: str) -> str:
    base = Path(file_name).stem
    suffix = Path(file_name).suffix
    index = 1
    candidate = os.path.join(folder_path, file_name)
    while os.path.exists(candidate):
        candidate = os.path.join(folder_path, f"{base} ({index}){suffix}")
        index += 1
    return candidate


