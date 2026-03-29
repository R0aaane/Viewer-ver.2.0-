import json
import os
from pathlib import Path

from fastapi import APIRouter, Depends, File, Form, Request, UploadFile

from server.core.errors import bad_request
from server.core.media_formats import is_supported_media_extension, normalized_extension
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
    artistTag: str | None = Form(None),
    seriesTag: str | None = Form(None),
    freeTagsJson: str | None = Form(None),
    characterTagsJson: str | None = Form(None),
    targetCollection: str | None = Form(None),
    organizeAfterImport: bool = Form(False),
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
    saved_paths: list[str] = []

    for upload in files:
        file_name = (upload.filename or "").strip()
        if not file_name:
            skipped_count += 1
            continue

        if not is_supported_media_extension(normalized_extension(file_name)):
            raise bad_request(f"未対応のファイル形式です: {file_name}")

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
            saved_paths.append(destination)
            imported_count += 1
        finally:
            await upload.close()

    tagged_count = 0
    organized_count = 0
    rescanned_count = 0

    if imported_count > 0:
        index_service = request.app.state.index_service
        metadata_store = request.app.state.metadata_store
        index_service.scan_folder(folder_path)

        import_tags = _build_import_tags(
            artist_tag=artistTag,
            series_tag=seriesTag,
            free_tags=_parse_json_tag_list(freeTagsJson, field_name="freeTagsJson"),
            character_tags=_parse_json_tag_list(characterTagsJson, field_name="characterTagsJson"),
        )

        imported_media_ids: list[str] = []
        unresolved_paths: list[str] = []
        for saved_path in saved_paths:
            try:
                imported_media_ids.append(
                    metadata_store.resolve_media_id(
                        saved_path,
                        identity={"aliases": [saved_path]},
                    )
                )
            except Exception:
                unresolved_paths.append(saved_path)

        if unresolved_paths and (import_tags or organizeAfterImport):
            failed_name = os.path.basename(unresolved_paths[0])
            raise bad_request(f"取り込み後のメディア認識に失敗しました: {failed_name}")

        if import_tags and imported_media_ids:
            for media_id in imported_media_ids:
                metadata_store.add_tags_to_media(media_id, import_tags)
            tagged_count = len(imported_media_ids)

        if organizeAfterImport and imported_media_ids:
            organized = metadata_store.organize_media_by_tags(
                library_root=folder_path,
                media_ids=imported_media_ids,
            )
            organized_count = len(organized)

        rescanned_count = index_service.scan_folder(folder_path)

    response = {
        "ok": True,
        "importedCount": imported_count,
        "skippedCount": skipped_count,
        "taggedCount": tagged_count,
        "organizedCount": organized_count,
        "rescannedCount": rescanned_count,
    }
    if targetCollection is not None:
        response["targetCollection"] = targetCollection
    return response


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


def _build_import_tags(
    *,
    artist_tag: str | None,
    series_tag: str | None,
    free_tags: list[str],
    character_tags: list[str],
) -> list[dict[str, str]]:
    tags: list[dict[str, str]] = []
    seen: set[tuple[str, str]] = set()

    def append_tag(category: str, name: str | None) -> None:
        raw_name = (name or "").strip()
        if not raw_name:
            return
        key = (category, raw_name.casefold())
        if key in seen:
            return
        seen.add(key)
        tags.append({"category": category, "name": raw_name})

    append_tag("artist", artist_tag)
    append_tag("series", series_tag)
    for name in character_tags:
        append_tag("character", name)
    for name in free_tags:
        append_tag("free", name)
    return tags


def _parse_json_tag_list(raw: str | None, *, field_name: str) -> list[str]:
    if raw is None or not raw.strip():
        return []

    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        raise bad_request(f"{field_name} の JSON が不正です") from error

    if not isinstance(value, list):
        raise bad_request(f"{field_name} は配列で指定してください")

    out: list[str] = []
    for entry in value:
        if not isinstance(entry, str):
            raise bad_request(f"{field_name} には文字列のみ指定できます")
        trimmed = entry.strip()
        if trimmed:
            out.append(trimmed)
    return out


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


