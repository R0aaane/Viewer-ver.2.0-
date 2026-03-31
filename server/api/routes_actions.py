import json
import logging
import os
import re
import shutil
import unicodedata
from pathlib import Path

from fastapi import APIRouter, Depends, File, Form, Request, UploadFile

from server.core.errors import ApiError, bad_request, server_error
from server.core.media_formats import is_supported_media_extension, normalized_extension
from server.models.dto import (
    DeleteRequest,
    DownloadUrlRequest,
    DownloadUrlResponse,
    MessageResponse,
    RenameRequest,
    RescanRequest,
)
from server.services.auth_service import require_bearer_token
from server.services.import_tag_rule_service import build_inferred_import_tags, filter_hitomi_pdf_auto_tags
from server.services.url_download_service import UrlDownloadError, UrlDownloadOptions


router = APIRouter(tags=["actions"], dependencies=[Depends(require_bearer_token)])
logger = logging.getLogger(__name__)



@router.post("/rescan", response_model=MessageResponse)
def request_rescan(
    request: Request,
    payload: RescanRequest | None = None,
) -> MessageResponse:
    index_service = request.app.state.index_service
    settings = request.app.state.settings

    target = (payload.folderRaw if payload else "") or ""
    target = os.path.normpath(target.strip()) if target.strip() else ""

    try:
        if target:
            logger.info("[rescan] request target=%s", target)
            scanned = index_service.scan_folder(target)
            logger.info("[rescan] completed target=%s scanned=%s", target, scanned)
            return MessageResponse(message=f"再スキャンが完了しました: {scanned} 件")

        logger.info("[rescan] request configured_roots=%s", settings.media_roots)
        results = index_service.rescan_configured_roots(settings.media_roots)
        total = sum(int(entry["count"]) for entry in results)
        logger.info("[rescan] completed configured_roots total=%s details=%s", total, results)
        return MessageResponse(message=f"再スキャンが完了しました: {total} 件")
    except ApiError:
        raise
    except Exception as error:
        logger.exception("[rescan] unexpected failure target=%s roots=%s", target or None, settings.media_roots)
        raise server_error(f"再スキャンに失敗しました: {error}") from error


@router.post("/upload")
async def upload_files(
    request: Request,
    folderRaw: str = Form(...),
    skipIfExists: bool = Form(True),
    artistTag: str | None = Form(None),
    seriesTag: str | None = Form(None),
    freeTagsJson: str | None = Form(None),
    characterTagsJson: str | None = Form(None),
    fileTagsJson: str | None = Form(None),
    sourceRelativePathsJson: str | None = Form(None),
    originalDisplayNamesJson: str | None = Form(None),
    targetCollection: str | None = Form(None),
    organizeAfterImport: bool = Form(False),
    files: list[UploadFile] = File(...),
) -> dict[str, object]:
    if not files:
        raise bad_request("アップロード対象のファイルがありません")

    settings = request.app.state.settings
    folder_path = os.path.normpath(folderRaw)
    if not os.path.isdir(folder_path):
        raise bad_request(f"保存先フォルダが存在しません: {folderRaw}")
    if settings.media_roots and not any(_is_inside_root(folder_path, root) for root in settings.media_roots):
        raise bad_request("保存先フォルダが許可されたメディアルートの外にあります")

    source_relative_paths = _parse_json_string_list(
        sourceRelativePathsJson,
        field_name="sourceRelativePathsJson",
        preserve_empty=True,
    )
    if source_relative_paths and len(source_relative_paths) != len(files):
        raise bad_request("sourceRelativePathsJson の件数がファイル数と一致しません")

    original_display_names = _parse_json_string_list(
        originalDisplayNamesJson,
        field_name="originalDisplayNamesJson",
        preserve_empty=True,
    )
    if original_display_names and len(original_display_names) != len(files):
        raise bad_request("originalDisplayNamesJson の件数がファイル数と一致しません")

    file_tag_groups = _parse_json_tag_groups(fileTagsJson, field_name="fileTagsJson")
    if file_tag_groups and len(file_tag_groups) != len(files):
        raise bad_request("fileTagsJson length must match files")

    imported_count = 0
    skipped_count = 0
    saved_entries: list[tuple[str, str, list[dict[str, str]]]] = []

    for index, upload in enumerate(files):
        multipart_file_name = _normalize_upload_file_name(upload.filename or "")
        original_display_name = (
            original_display_names[index] if index < len(original_display_names) else ""
        )
        file_name = _resolve_upload_file_name(
            original_display_name=original_display_name,
            multipart_file_name=multipart_file_name,
        )
        relative_path_hint = source_relative_paths[index] if index < len(source_relative_paths) else ""
        file_tags = file_tag_groups[index] if index < len(file_tag_groups) else []

        logger.info(
            "[upload] received index=%s multipart_filename=%r original_display_name=%r final_filename=%r utf8_multipart=%s utf8_original=%s",
            index,
            upload.filename,
            original_display_name,
            file_name,
            _utf8_hex_preview(upload.filename or ""),
            _utf8_hex_preview(original_display_name),
        )

        if not file_name:
            skipped_count += 1
            await upload.close()
            continue

        if not is_supported_media_extension(normalized_extension(file_name)):
            raise bad_request(f"未対応のファイル形式です: {file_name}")

        destination = os.path.join(folder_path, file_name)
        if os.path.exists(destination):
            if skipIfExists:
                skipped_count += 1
                await upload.close()
                continue
            destination = _unique_path(folder_path, file_name)

        logger.info(
            "[upload] saving index=%s destination=%r final_filename=%r relative_hint=%r",
            index,
            destination,
            file_name,
            relative_path_hint,
        )

        try:
            with open(destination, "wb") as handle:
                while True:
                    chunk = await upload.read(1024 * 1024)
                    if not chunk:
                        break
                    handle.write(chunk)
            saved_entries.append((os.path.normpath(destination), relative_path_hint, file_tags))
            imported_count += 1
        except Exception:
            logger.exception(
                "[upload] failed to save index=%s multipart_filename=%r original_display_name=%r final_filename=%r",
                index,
                upload.filename,
                original_display_name,
                file_name,
            )
            raise
        finally:
            await upload.close()

    tagged_count = 0
    organized_count = 0
    rescanned_count = 0

    if imported_count > 0:
        index_service = request.app.state.index_service
        metadata_store = request.app.state.metadata_store
        rescanned_count = index_service.index_files([saved_path for saved_path, _, _ in saved_entries])

        common_tags = _build_import_tags(
            artist_tag=artistTag,
            series_tag=seriesTag,
            free_tags=_parse_json_tag_list(freeTagsJson, field_name="freeTagsJson"),
            character_tags=_parse_json_tag_list(characterTagsJson, field_name="characterTagsJson"),
        )

        resolved_entries: list[tuple[str, list[dict[str, str]]]] = []
        imported_media_ids: list[str] = []
        unresolved_paths: list[str] = []
        has_any_tags = bool(common_tags)
        for saved_path, _, file_tags in saved_entries:
            merged_tags = _merge_import_tags(common_tags, file_tags)
            if merged_tags:
                has_any_tags = True
            try:
                media_id = metadata_store.resolve_media_id(
                    saved_path,
                    identity={"aliases": [saved_path]},
                )
            except Exception:
                unresolved_paths.append(saved_path)
                logger.exception("[upload] failed to resolve media id for %r", saved_path)
                continue
            imported_media_ids.append(media_id)
            resolved_entries.append((media_id, merged_tags))

        if unresolved_paths and (has_any_tags or organizeAfterImport):
            failed_name = os.path.basename(unresolved_paths[0])
            raise bad_request(f"取り込み後のメディア解決に失敗しました: {failed_name}")

        for media_id, merged_tags in resolved_entries:
            if not merged_tags:
                continue
            metadata_store.add_tags_to_media(media_id, merged_tags)
            tagged_count += 1

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

@router.post("/download-url", response_model=DownloadUrlResponse)
async def download_url(
    request: Request,
    payload: DownloadUrlRequest,
) -> DownloadUrlResponse:
    source_url = payload.url.strip() or "\n".join(entry.strip() for entry in payload.urls if entry.strip())
    options = UrlDownloadOptions(
        cookie_file_path=payload.cookieFilePath,
        cookie_mode=payload.cookieMode,
        url_list_file_path=payload.urlListFilePath,
        sites=payload.sites,
        favorite_posts=payload.favoritePosts,
        favorite_user_services=payload.favoriteUserServices,
        media_type=payload.mediaType,
        parallel_downloads=payload.parallelDownloads,
        include_inline_images=payload.inline,
        include_post_content=payload.content,
        include_comments=payload.comments,
        save_json=payload.saveJson,
        overwrite_existing_files=payload.overwrite,
        verbose=payload.verbose,
        convert_hitomi_to_pdf=payload.convertHitomiToPdf,
    )
    if not options.has_any_source(source_url):
        raise bad_request("URL?URL ??????????????????????????")

    settings = request.app.state.settings
    folder_path = os.path.normpath(payload.folderRaw)
    if not os.path.isdir(folder_path):
        raise bad_request(f"??????????????: {payload.folderRaw}")
    if settings.media_roots and not any(_is_inside_root(folder_path, root) for root in settings.media_roots):
        raise bad_request("?????????????????????")

    before_paths = _collect_media_paths(folder_path)

    try:
        download_result = await request.app.state.url_download_service.download_url(
            source_url=source_url,
            destination_folder=folder_path,
            options=options,
        )
    except UrlDownloadError as error:
        raise bad_request(str(error)) from error

    tagged_count = 0
    organized_count = 0
    rescanned_count = 0

    if download_result.imported_count > 0:
        index_service = request.app.state.index_service
        metadata_store = request.app.state.metadata_store
        common_tags = _build_import_tags(
            artist_tag=payload.artistTag,
            series_tag=payload.seriesTag,
            free_tags=payload.freeTags,
            character_tags=payload.characterTags,
        )
        source_urls = _collect_source_urls(payload.url, payload.urls)

        after_paths = _collect_media_paths(folder_path)
        imported_paths = sorted(after_paths.difference(before_paths))
        flattened_entries = _flatten_imported_media_paths(folder_path, imported_paths)
        rescanned_count = index_service.scan_folder(folder_path)

        resolved_entries: list[tuple[str, list[dict[str, str]]]] = []
        imported_media_ids: list[str] = []
        unresolved_paths: list[str] = []
        has_any_tags = bool(common_tags)
        for saved_path, relative_path_hint in flattened_entries:
            inferred_tags = []
            if normalized_extension(saved_path) == ".pdf":
                inferred_tags = filter_hitomi_pdf_auto_tags(
                    build_inferred_import_tags(
                        relative_path=relative_path_hint,
                        source_urls=source_urls,
                    )
                )
            merged_tags = _merge_import_tags(common_tags, inferred_tags)
            if merged_tags:
                has_any_tags = True
            try:
                media_id = metadata_store.resolve_media_id(
                    saved_path,
                    identity={"aliases": [saved_path]},
                )
            except Exception:
                unresolved_paths.append(saved_path)
                continue
            imported_media_ids.append(media_id)
            resolved_entries.append((media_id, merged_tags))

        if unresolved_paths and (has_any_tags or payload.organizeAfterImport):
            failed_name = os.path.basename(unresolved_paths[0])
            raise bad_request(f"???????????????????: {failed_name}")

        for media_id, merged_tags in resolved_entries:
            if not merged_tags:
                continue
            metadata_store.add_tags_to_media(media_id, merged_tags)
            tagged_count += 1

        if payload.organizeAfterImport and imported_media_ids:
            organized = metadata_store.organize_media_by_tags(
                library_root=folder_path,
                media_ids=imported_media_ids,
            )
            organized_count = len(organized)
            rescanned_count = index_service.scan_folder(folder_path)

    return DownloadUrlResponse(
        importedCount=download_result.imported_count,
        skippedCount=download_result.skipped_count,
        failedCount=download_result.failed_count,
        taggedCount=tagged_count,
        organizedCount=organized_count,
        rescannedCount=rescanned_count,
        targetCollection=payload.targetCollection,
    )


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
    return MessageResponse(message="リネームしました")


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
    return MessageResponse(message=f"削除しました ({deleted} 件)")


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


def _merge_import_tags(*tag_groups: list[dict[str, str]]) -> list[dict[str, str]]:
    merged: list[dict[str, str]] = []
    seen: set[tuple[str, str]] = set()
    for group in tag_groups:
        for tag in group:
            category = str(tag.get("category") or "").strip()
            name = str(tag.get("name") or "").strip()
            if not category or not name:
                continue
            key = (category, name.casefold())
            if key in seen:
                continue
            seen.add(key)
            merged.append({"category": category, "name": name})
    return merged


def _parse_json_tag_list(raw: str | None, *, field_name: str) -> list[str]:
    return _parse_json_string_list(raw, field_name=field_name)



def _parse_json_tag_groups(
    raw: str | None,
    *,
    field_name: str,
) -> list[list[dict[str, str]]]:
    if raw is None or not raw.strip():
        return []

    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        raise bad_request(f"{field_name} must be valid JSON") from error

    if not isinstance(value, list):
        raise bad_request(f"{field_name} must be a JSON array")

    out: list[list[dict[str, str]]] = []
    for group in value:
        if group is None:
            out.append([])
            continue
        if not isinstance(group, list):
            raise bad_request(f"{field_name} entries must be arrays")

        normalized_group: list[dict[str, str]] = []
        seen: set[tuple[str, str]] = set()
        for raw_tag in group:
            if not isinstance(raw_tag, dict):
                raise bad_request(f"{field_name} tags must be objects")
            category = str(raw_tag.get("category") or "").strip()
            name = str(raw_tag.get("name") or "").strip()
            if not category or not name:
                continue
            key = (category, name.casefold())
            if key in seen:
                continue
            seen.add(key)
            normalized_group.append({"category": category, "name": name})
        out.append(normalized_group)

    return out

def _parse_json_string_list(
    raw: str | None,
    *,
    field_name: str,
    preserve_empty: bool = False,
) -> list[str]:
    if raw is None or not raw.strip():
        return []

    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        raise bad_request(f"{field_name} は JSON 配列で指定してください") from error

    if not isinstance(value, list):
        raise bad_request(f"{field_name} は文字列配列で指定してください")

    out: list[str] = []
    for entry in value:
        if not isinstance(entry, str):
            raise bad_request(f"{field_name} の各要素は文字列である必要があります")
        trimmed = entry.strip()
        if trimmed or preserve_empty:
            out.append(trimmed)
    return out


def _collect_source_urls(primary_url: str, extra_urls: list[str]) -> list[str]:
    urls: list[str] = []
    seen: set[str] = set()
    for raw in [primary_url, *extra_urls]:
        for chunk in str(raw or "").replace(",", "\n").splitlines():
            trimmed = chunk.strip()
            if not trimmed or trimmed in seen:
                continue
            seen.add(trimmed)
            urls.append(trimmed)
    return urls


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



def _normalize_upload_file_name(raw_name: str) -> str:
    file_name = str(raw_name or "").strip()
    if not file_name:
        return ""

    try:
        decoded = json.loads(file_name)
    except json.JSONDecodeError:
        decoded = None

    if isinstance(decoded, list):
        first = next(
            (
                str(entry).strip()
                for entry in decoded
                if isinstance(entry, str) and str(entry).strip()
            ),
            "",
        )
        file_name = first or file_name
    elif isinstance(decoded, str) and decoded.strip():
        file_name = decoded.strip()

    return _sanitize_upload_display_name(file_name)



def _resolve_upload_file_name(
    *,
    original_display_name: str,
    multipart_file_name: str,
) -> str:
    original_name = _sanitize_upload_display_name(original_display_name)
    multipart_name = _sanitize_upload_display_name(multipart_file_name)
    if original_name:
        if not normalized_extension(original_name) and normalized_extension(multipart_name):
            original_name = f"{original_name}{Path(multipart_name).suffix}"
        return original_name
    return multipart_name



def _sanitize_upload_display_name(raw_name: str) -> str:
    file_name = unicodedata.normalize("NFC", str(raw_name or "").strip())
    if not file_name:
        return ""

    file_name = Path(file_name.replace("\\", "/")).name.strip()
    file_name = re.sub(r'[<>:"/\\|?*\x00-\x1F]+', "_", file_name)
    file_name = file_name.rstrip(" .")
    if not file_name or file_name in {".", ".."}:
        return ""
    return file_name



def _utf8_hex_preview(value: str) -> str:
    raw = str(value or "").encode("utf-8", errors="replace")
    preview = raw[:32].hex()
    if len(raw) > 32:
        preview += "..."
    return preview


def _collect_media_paths(folder_path: str) -> set[str]:
    found: set[str] = set()
    for base, _, files in os.walk(folder_path):
        for file_name in files:
            if not is_supported_media_extension(normalized_extension(file_name)):
                continue
            found.add(os.path.normpath(os.path.join(base, file_name)))
    return found


def _flatten_imported_media_paths(
    folder_path: str,
    imported_paths: list[str],
) -> list[tuple[str, str]]:
    flattened: list[tuple[str, str]] = []
    normalized_root = os.path.normcase(os.path.normpath(folder_path))

    for raw_path in imported_paths:
        source_path = os.path.normpath(raw_path)
        relative_path = os.path.relpath(source_path, folder_path).replace("\\", "/")
        source_parent = os.path.normcase(os.path.dirname(source_path))
        if source_parent == normalized_root:
            flattened.append((source_path, relative_path))
            continue

        file_name = os.path.basename(source_path)
        target_path = os.path.normpath(os.path.join(folder_path, file_name))
        if os.path.normcase(target_path) == os.path.normcase(source_path):
            flattened.append((source_path, relative_path))
            continue
        if os.path.exists(target_path):
            target_path = _unique_path(folder_path, file_name)

        shutil.move(source_path, target_path)
        flattened.append((os.path.normpath(target_path), relative_path))

    _remove_empty_dirs(folder_path)
    return flattened


def _remove_empty_dirs(folder_path: str) -> None:
    root = os.path.normcase(os.path.normpath(folder_path))
    for base, _, _ in os.walk(folder_path, topdown=False):
        normalized_base = os.path.normcase(os.path.normpath(base))
        if normalized_base == root:
            continue
        try:
            if not os.listdir(base):
                os.rmdir(base)
        except OSError:
            continue