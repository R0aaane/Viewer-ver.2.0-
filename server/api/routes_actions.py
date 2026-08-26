import json
import logging
import os
import posixpath
import re
import secrets
import shutil
import tempfile
import time
import unicodedata
from pathlib import Path
from urllib.parse import quote

from fastapi import APIRouter, Depends, File, Form, Request, UploadFile
from fastapi.responses import FileResponse
from PIL import Image, ImageOps, UnidentifiedImageError

from server.core.errors import ApiError, bad_request, server_error
from server.core.media_formats import (
    is_supported_image_extension,
    is_supported_media_extension,
    normalized_extension,
)
from server.models.dto import (
    DeleteRequest,
    DownloadUrlRequest,
    DownloadUrlResponse,
    DownloadUrlStatusResponse,
    MessageResponse,
    OrganizeLibraryRequest,
    OrganizeLibraryResponse,
    RenameRequest,
    RescanRequest,
)
from server.services.auth_service import require_bearer_token
from server.services.app_update_store import save_app_update_upload, update_download_path
from server.services.import_tag_rule_service import (
    build_inferred_import_tags,
    filter_hitomi_pdf_auto_tags,
    filter_supported_url_import_image_tags,
)
from server.services.url_download_service import UrlDownloadError, UrlDownloadOptions
from server.vendor.kemono_dl.hitomi import strip_hitomi_download_prefix


router = APIRouter(tags=["actions"], dependencies=[Depends(require_bearer_token)])
logger = logging.getLogger(__name__)


def _url_download_status_store(request: Request) -> dict[str, dict[str, object]]:
    store = getattr(request.app.state, "url_download_statuses", None)
    if not isinstance(store, dict):
        store = {}
        request.app.state.url_download_statuses = store
    return store


def _set_url_download_status(
    request: Request,
    request_id: str,
    *,
    status: str,
    total: int = 0,
    completed: int = 0,
    success: int = 0,
    failed: int = 0,
    skipped: int = 0,
    current_file: str | None = None,
) -> None:
    store = _url_download_status_store(request)
    store[request_id] = {
        "requestId": request_id,
        "status": status,
        "total": max(0, int(total or 0)),
        "completed": max(0, int(completed or 0)),
        "success": max(0, int(success or 0)),
        "failed": max(0, int(failed or 0)),
        "skipped": max(0, int(skipped or 0)),
        "currentFile": current_file,
        "updatedAt": time.time(),
    }


def _as_status_int(value: object, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default



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
            backfill = request.app.state.metadata_store.backfill_configured_tag_aliases()
            logger.info("[rescan] completed target=%s scanned=%s", target, scanned)
            return MessageResponse(
                message=(
                    f"Rescan completed: {scanned} items "
                    f"(tag aliases updated: {backfill['removedAliasCount']})"
                )
            )

        logger.info("[rescan] request configured_roots=%s", settings.media_roots)
        results = index_service.rescan_configured_roots(settings.media_roots)
        backfill = request.app.state.metadata_store.backfill_configured_tag_aliases()
        total = sum(int(entry["count"]) for entry in results)
        logger.info("[rescan] completed configured_roots total=%s details=%s", total, results)
        return MessageResponse(
            message=(
                f"Rescan completed: {total} items "
                f"(tag aliases updated: {backfill['removedAliasCount']})"
            )
        )
    except ApiError:
        raise
    except Exception as error:
        logger.exception("[rescan] unexpected failure target=%s roots=%s", target or None, settings.media_roots)
        raise server_error(f"Rescan failed: {error}") from error


@router.post("/app-update/upload")
async def upload_app_update(
    request: Request,
    version: str = Form(...),
    file: UploadFile = File(...),
) -> dict[str, object]:
    try:
        info = await save_app_update_upload(
            request.app.state.settings,
            version=_resolve_form_string(version),
            upload=file,
        )
        return {
            "ok": True,
            "version": info.version,
            "fileName": info.file_name,
            "originalFileName": info.original_file_name,
            "sizeBytes": info.size_bytes,
            "updateUrl": update_download_path(info),
        }
    finally:
        await file.close()


@router.post("/xviewer/saved-images")
async def save_xviewer_saved_image(
    request: Request,
    accountFolderName: str = Form(""),
    file: UploadFile = File(...),
) -> dict[str, object]:
    settings = request.app.state.settings
    folder_name = _sanitize_upload_display_name(accountFolderName or "") or "unknown_user"
    file_name = _sanitize_upload_display_name(file.filename or "") or "image.jpg"
    target_dir = settings.xviewer_saved_images_dir / folder_name
    target_dir.mkdir(parents=True, exist_ok=True)
    destination = target_dir / file_name

    if destination.exists():
        stem = destination.stem
        suffix = destination.suffix
        for index in range(2, 10000):
            candidate = target_dir / f"{stem}_{index}{suffix}"
            if not candidate.exists():
                destination = candidate
                break

    try:
        await _save_upload_file_atomic(
            file,
            destination,
            index=0,
            request_id="xviewer",
        )
        return {
            "ok": True,
            "savedPath": str(destination),
            "displayName": destination.name,
        }
    finally:
        await file.close()


@router.get("/xviewer/saved-images")
def list_xviewer_saved_images(request: Request) -> dict[str, object]:
    root = _resolve_xviewer_saved_images_root(request)
    if not root.exists():
        return {
            "items": [],
            "rootPath": str(root),
            "rootExists": False,
        }

    items: list[dict[str, object]] = []
    for path in root.rglob("*"):
      if not path.is_file() or not is_supported_image_extension(path.suffix):
          continue
      relative_path = path.relative_to(root).as_posix()
      parts = path.relative_to(root).parts
      author = parts[0] if len(parts) > 1 else "unknown_user"
      stat = path.stat()
      items.append({
          "relativePath": relative_path,
          "fileName": path.name,
          "authorUsername": author,
          "savedPath": str(path),
          "sizeBytes": stat.st_size,
          "modifiedEpochMs": int(stat.st_mtime * 1000),
          "downloadPath": f"/xviewer/saved-images/file?relativePath={quote(relative_path)}",
      })

    items.sort(key=lambda item: str(item["relativePath"]).lower())
    return {
        "items": items,
        "rootPath": str(root),
        "rootExists": True,
        "itemCount": len(items),
    }


@router.get("/xviewer/saved-images/file")
def get_xviewer_saved_image_file(request: Request, relativePath: str) -> FileResponse:
    root = _resolve_xviewer_saved_images_root(request).resolve()
    target = (root / relativePath).resolve()
    if not str(target).lower().startswith(str(root).lower()) or not target.is_file():
        raise bad_request("Saved image file was not found")
    if not is_supported_image_extension(target.suffix):
        raise bad_request("Unsupported saved image file")
    return FileResponse(target)


def _resolve_xviewer_saved_images_root(request: Request) -> Path:
    settings = request.app.state.settings
    candidates = [
        Path("D:/Xsaved_images"),
        Path("D:/xSaved_images"),
        settings.xviewer_saved_images_dir,
    ]
    for media_root in getattr(settings, "media_roots", []) or []:
        try:
            candidates.append(Path(media_root).resolve().parent / "Xsaved_images")
        except Exception:
            pass

    seen: set[str] = set()
    for candidate in candidates:
        root = candidate.resolve()
        key = str(root).lower()
        if key in seen:
            continue
        seen.add(key)
        if root.exists() and any(
            path.is_file() and is_supported_image_extension(path.suffix)
            for path in root.rglob("*")
        ):
            return root
    return settings.xviewer_saved_images_dir


@router.post("/organize", response_model=OrganizeLibraryResponse)
def organize_library(
    request: Request,
    payload: OrganizeLibraryRequest,
) -> OrganizeLibraryResponse:
    settings = request.app.state.settings
    folder_path = os.path.normpath(payload.folderRaw)
    if not os.path.isdir(folder_path):
        raise bad_request(f"Destination folder does not exist: {payload.folderRaw}")
    if settings.media_roots and not any(_is_inside_root(folder_path, root) for root in settings.media_roots):
        raise bad_request("folderRaw must be inside configured media roots")

    try:
        moved = request.app.state.metadata_store.organize_media_by_tags(
            library_root=folder_path,
            media_ids=None,
        )
        rescanned_count = request.app.state.index_service.scan_folder(folder_path)
        return OrganizeLibraryResponse(
            moved=moved,
            movedCount=len(moved),
            rescannedCount=rescanned_count,
        )
    except ApiError:
        raise
    except Exception as error:
        logger.exception('[organize] unexpected failure folder=%s', folder_path)
        raise server_error(f"Organize failed: {error}") from error


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
    convertToPdfOnHost: bool = Form(False),
    hostPdfNameHint: str | None = Form(None),
    hostPdfFileNameHint: str | None = Form(None),
    organizeAfterImport: bool = Form(False),
    uploadRequestId: str | None = Form(None),
    files: list[UploadFile] = File(...),
) -> dict[str, object]:
    folderRaw = _resolve_form_string(folderRaw)
    artistTag = _resolve_optional_form_string(artistTag)
    seriesTag = _resolve_optional_form_string(seriesTag)
    freeTagsJson = _resolve_optional_form_string(freeTagsJson)
    characterTagsJson = _resolve_optional_form_string(characterTagsJson)
    fileTagsJson = _resolve_optional_form_string(fileTagsJson)
    sourceRelativePathsJson = _resolve_optional_form_string(sourceRelativePathsJson)
    originalDisplayNamesJson = _resolve_optional_form_string(originalDisplayNamesJson)
    targetCollection = _resolve_optional_form_string(targetCollection)
    hostPdfNameHint = _resolve_optional_form_string(hostPdfNameHint)
    hostPdfFileNameHint = _resolve_optional_form_string(hostPdfFileNameHint)
    uploadRequestId = _resolve_optional_form_string(uploadRequestId)
    skipIfExists = _resolve_form_bool(skipIfExists, default=True)
    convertToPdfOnHost = _resolve_form_bool(convertToPdfOnHost, default=False)
    organizeAfterImport = _resolve_form_bool(organizeAfterImport, default=False)
    if hostPdfNameHint is None or not hostPdfNameHint.strip():
        hostPdfNameHint = hostPdfFileNameHint
    request_id = _normalize_upload_request_id(uploadRequestId)
    logger.info(
        '[UPLOAD][SERVER][req:%s] received metadata folderRaw=%s skipIfExists=%s artistTag=%s seriesTag=%s characterTagsJson=%s freeTagsJson=%s fileTagsJson=%s sourceRelativePathsJson=%s targetCollection=%s convertToPdfOnHost=%s hostPdfNameHint=%s organizeAfterImport=%s files=%s',
        request_id,
        _log_scalar(folderRaw),
        skipIfExists,
        _log_scalar(artistTag),
        _log_scalar(seriesTag),
        _log_scalar(characterTagsJson),
        _log_scalar(freeTagsJson),
        _log_scalar(fileTagsJson),
        _log_scalar(sourceRelativePathsJson),
        _log_scalar(targetCollection),
        convertToPdfOnHost,
        _log_scalar(hostPdfNameHint),
        organizeAfterImport,
        len(files),
    )
    if not files:
        raise bad_request("No files were provided for upload")

    settings = request.app.state.settings
    folder_path = os.path.normpath(folderRaw)
    if not os.path.isdir(folder_path):
        raise bad_request(f"Destination folder does not exist: {folderRaw}")
    if settings.media_roots and not any(_is_inside_root(folder_path, root) for root in settings.media_roots):
        raise bad_request("folderRaw must be inside configured media roots")

    try:
        source_relative_paths = _parse_json_string_list(
            sourceRelativePathsJson,
            field_name="sourceRelativePathsJson",
            preserve_empty=True,
        )
        logger.info(
            '[UPLOAD][SERVER][req:%s] parse_success field=sourceRelativePathsJson value=%s',
            request_id,
            _log_string_list(source_relative_paths),
        )
    except Exception:
        logger.exception(
            '[UPLOAD][ERROR][req:%s] parse_failed field=sourceRelativePathsJson raw=%s',
            request_id,
            _log_scalar(sourceRelativePathsJson),
        )
        raise
    if source_relative_paths and len(source_relative_paths) != len(files):
        raise bad_request("sourceRelativePathsJson length must match files")

    try:
        original_display_names = _parse_json_string_list(
            originalDisplayNamesJson,
            field_name="originalDisplayNamesJson",
            preserve_empty=True,
        )
        logger.info(
            '[UPLOAD][SERVER][req:%s] parse_success field=originalDisplayNamesJson value=%s',
            request_id,
            _log_string_list(original_display_names),
        )
    except Exception:
        logger.exception(
            '[UPLOAD][ERROR][req:%s] parse_failed field=originalDisplayNamesJson raw=%s',
            request_id,
            _log_scalar(originalDisplayNamesJson),
        )
        raise
    if original_display_names and len(original_display_names) != len(files):
        raise bad_request("originalDisplayNamesJson length must match files")

    try:
        file_tag_groups = _parse_json_tag_groups(fileTagsJson, field_name="fileTagsJson")
        logger.info(
            '[UPLOAD][SERVER][req:%s] parse_success field=fileTagsJson value=%s',
            request_id,
            _log_tag_groups(file_tag_groups),
        )
    except Exception:
        logger.exception(
            '[UPLOAD][ERROR][req:%s] parse_failed field=fileTagsJson raw=%s',
            request_id,
            _log_scalar(fileTagsJson),
        )
        raise
    if file_tag_groups and len(file_tag_groups) != len(files):
        raise bad_request("fileTagsJson length must match files")

    imported_count = 0
    skipped_count = 0
    saved_entries: list[tuple[str, str, list[dict[str, str]]]] = []
    host_pdf_saved_entries: list[tuple[str, str, list[dict[str, str]]]] = []
    host_pdf_temp_dir = tempfile.mkdtemp(prefix="upload-host-pdf-") if convertToPdfOnHost else ""
    attached_tags_by_media: dict[str, list[str]] = {}
    tag_attach_success_count = 0
    tag_attach_failure_count = 0

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
            '[UPLOAD][SERVER][req:%s] received_file index=%s multipart_filename=%r original_display_name=%r final_filename=%r sourceRelativePath=%s fileTags=%s utf8_multipart=%s utf8_original=%s',
            request_id,
            index,
            upload.filename,
            original_display_name,
            file_name,
            _log_scalar(relative_path_hint),
            _log_tag_list(file_tags),
            _utf8_hex_preview(upload.filename or ""),
            _utf8_hex_preview(original_display_name),
        )

        if not file_name:
            skipped_count += 1
            await upload.close()
            logger.info('[UPLOAD][SERVER][req:%s] skip index=%s reason=empty_filename', request_id, index)
            continue

        extension = normalized_extension(file_name)
        if not is_supported_media_extension(extension):
            raise bad_request(f"Unsupported media file type: {file_name}")
        if convertToPdfOnHost and not is_supported_image_extension(extension):
            raise bad_request("Host PDF conversion supports image files only")

        if convertToPdfOnHost:
            destination = os.path.join(
                host_pdf_temp_dir,
                f"{index:04d}_{_sanitize_upload_display_name(file_name)}",
            )
        else:
            destination = os.path.join(folder_path, file_name)
            if os.path.exists(destination):
                if skipIfExists:
                    skipped_count += 1
                    await upload.close()
                    logger.info('[UPLOAD][SERVER][req:%s] skip index=%s destination=%s reason=exists', request_id, index, _log_scalar(destination))
                    continue
                logger.info('[UPLOAD][SERVER][req:%s] overwrite index=%s destination=%s reason=explicit_overwrite', request_id, index, _log_scalar(destination))
        logger.info(
            '[UPLOAD][SERVER][req:%s] saving index=%s destination=%s final_filename=%s sourceRelativePath=%s',
            request_id,
            index,
            _log_scalar(destination),
            _log_scalar(file_name),
            _log_scalar(relative_path_hint),
        )

        try:
            await _save_upload_file_atomic(
                upload,
                destination,
                request_id=request_id,
                index=index,
            )
            normalized_destination = os.path.normpath(destination)
            if convertToPdfOnHost:
                host_pdf_saved_entries.append((normalized_destination, relative_path_hint, file_tags))
            else:
                saved_entries.append((normalized_destination, relative_path_hint, file_tags))
                imported_count += 1
            logger.info('[UPLOAD][SERVER][req:%s] save_success index=%s destination=%s', request_id, index, _log_scalar(destination))
        except Exception:
            logger.exception(
                '[UPLOAD][ERROR][req:%s] save_failed index=%s multipart_filename=%r original_display_name=%r final_filename=%r',
                request_id,
                index,
                upload.filename,
                original_display_name,
                file_name,
            )
            raise
        finally:
            await upload.close()

    if convertToPdfOnHost:
        try:
            if host_pdf_saved_entries:
                pdf_file_name = _build_host_pdf_file_name(
                    host_pdf_name_hint=hostPdfNameHint,
                    source_relative_paths=source_relative_paths,
                    original_display_names=original_display_names,
                )
                pdf_destination = os.path.normpath(os.path.join(folder_path, pdf_file_name))
                if os.path.exists(pdf_destination) and skipIfExists:
                    skipped_count += 1
                    logger.info(
                        '[UPLOAD][SERVER][req:%s] host_pdf_skip destination=%s reason=exists',
                        request_id,
                        _log_scalar(pdf_destination),
                    )
                else:
                    _convert_uploaded_images_to_pdf(
                        [saved_path for saved_path, _, _ in host_pdf_saved_entries],
                        pdf_destination,
                    )
                    merged_file_tags = _merge_import_tags(
                        *[file_tags for _, _, file_tags in host_pdf_saved_entries]
                    )
                    saved_entries.append((pdf_destination, pdf_file_name, merged_file_tags))
                    imported_count = 1
                    logger.info(
                        '[UPLOAD][SERVER][req:%s] host_pdf_success destination=%s sourceCount=%s',
                        request_id,
                        _log_scalar(pdf_destination),
                        len(host_pdf_saved_entries),
                    )
        finally:
            shutil.rmtree(host_pdf_temp_dir, ignore_errors=True)

    tagged_count = 0
    organized_count = 0
    rescanned_count = 0

    if imported_count > 0:
        index_service = request.app.state.index_service
        metadata_store = request.app.state.metadata_store
        should_organize_after_import = True
        rescanned_count = index_service.index_files([saved_path for saved_path, _, _ in saved_entries])

        try:
            free_tags = _parse_json_tag_list(freeTagsJson, field_name="freeTagsJson")
            logger.info('[UPLOAD][SERVER][req:%s] parse_success field=freeTagsJson value=%s', request_id, _log_string_list(free_tags))
        except Exception:
            logger.exception('[UPLOAD][ERROR][req:%s] parse_failed field=freeTagsJson raw=%s', request_id, _log_scalar(freeTagsJson))
            raise
        try:
            character_tags = _parse_json_tag_list(characterTagsJson, field_name="characterTagsJson")
            logger.info('[UPLOAD][SERVER][req:%s] parse_success field=characterTagsJson value=%s', request_id, _log_string_list(character_tags))
        except Exception:
            logger.exception('[UPLOAD][ERROR][req:%s] parse_failed field=characterTagsJson raw=%s', request_id, _log_scalar(characterTagsJson))
            raise

        common_tags = _build_import_tags(
            artist_tag=artistTag,
            series_tag=seriesTag,
            free_tags=free_tags,
            character_tags=character_tags,
        )
        logger.info('[TAG][SERVER][req:%s][artist] incoming=%s', request_id, _log_category_values(common_tags, 'artist'))
        logger.info('[TAG][SERVER][req:%s][series] incoming=%s', request_id, _log_category_values(common_tags, 'series'))
        logger.info('[TAG][SERVER][req:%s][character] incoming=%s', request_id, _log_category_values(common_tags, 'character'))
        logger.info('[TAG][SERVER][req:%s][free] incoming=%s', request_id, _log_category_values(common_tags, 'free'))

        resolved_entries: list[tuple[str, list[dict[str, str]]]] = []
        imported_media_ids: list[str] = []
        unresolved_paths: list[str] = []
        has_any_tags = bool(common_tags)
        for saved_path, relative_path_hint, file_tags in saved_entries:
            merged_tags = _merge_import_tags(common_tags, file_tags)
            if merged_tags:
                has_any_tags = True
            logger.info(
                '[TAG][SERVER][req:%s] item=%s sourceRelativePath=%s mergedTags=%s',
                request_id,
                _log_scalar(saved_path),
                _log_scalar(relative_path_hint),
                _log_tag_list(merged_tags),
            )
            logger.info('[TAG][SERVER][req:%s][artist] incoming=%s item=%s', request_id, _log_category_values(merged_tags, 'artist'), _log_scalar(saved_path))
            logger.info('[TAG][SERVER][req:%s][series] incoming=%s item=%s', request_id, _log_category_values(merged_tags, 'series'), _log_scalar(saved_path))
            logger.info('[TAG][SERVER][req:%s][character] incoming=%s item=%s', request_id, _log_category_values(merged_tags, 'character'), _log_scalar(saved_path))
            logger.info('[TAG][SERVER][req:%s][free] incoming=%s item=%s', request_id, _log_category_values(merged_tags, 'free'), _log_scalar(saved_path))
            try:
                media_id = metadata_store.resolve_media_id(
                    saved_path,
                    identity={"aliases": [saved_path]},
                )
                logger.info('[UPLOAD][SERVER][req:%s] resolve_media_id success path=%s mediaId=%s', request_id, _log_scalar(saved_path), _log_scalar(media_id))
            except Exception:
                unresolved_paths.append(saved_path)
                logger.exception('[UPLOAD][ERROR][req:%s] resolve_media_id failed path=%s', request_id, _log_scalar(saved_path))
                continue
            imported_media_ids.append(media_id)
            resolved_entries.append((media_id, merged_tags))

        if unresolved_paths and (has_any_tags or should_organize_after_import):
            failed_name = os.path.basename(unresolved_paths[0])
            raise bad_request(f"Failed to resolve media identity after save: {failed_name}")

        for media_id, merged_tags in resolved_entries:
            if not merged_tags:
                logger.info('[UPLOAD][SERVER][req:%s] tag_attach_skipped itemId=%s reason=no_tags', request_id, _log_scalar(media_id))
                continue
            try:
                metadata_store.add_tags_to_media(media_id, merged_tags, request_id=request_id)
                tagged_count += 1
                tag_attach_success_count += sum(1 for tag in merged_tags if str(tag.get('name') or '').strip())
                attached_tags = metadata_store.get_tags_for_media(media_id)
                attached_tags_by_media[media_id] = [
                    f"{tag['category']}:{tag['name']}"
                    for tag in attached_tags
                ]
                logger.info(
                    '[UPLOAD][RESULT][req:%s] itemId=%s attachedTags=%s',
                    request_id,
                    _log_scalar(media_id),
                    _log_string_list(attached_tags_by_media[media_id]),
                )
            except Exception:
                tag_attach_failure_count += sum(1 for tag in merged_tags if str(tag.get('name') or '').strip())
                logger.exception(
                    '[UPLOAD][ERROR][req:%s] tag_attach_failed itemId=%s mergedTags=%s',
                    request_id,
                    _log_scalar(media_id),
                    _log_tag_list(merged_tags),
                )
                raise

        if should_organize_after_import and imported_media_ids:
            organized = metadata_store.organize_media_by_tags(
                library_root=folder_path,
                media_ids=imported_media_ids,
            )
            organized_count = len(organized)
            rescanned_count = index_service.scan_folder(folder_path)

    response = {
        "ok": True,
        "requestId": request_id,
        "importedCount": imported_count,
        "skippedCount": skipped_count,
        "taggedCount": tagged_count,
        "organizedCount": organized_count,
        "rescannedCount": rescanned_count,
        "tagAttachSuccessCount": tag_attach_success_count,
        "tagAttachFailureCount": tag_attach_failure_count,
        "attachedTagsByMedia": attached_tags_by_media,
    }
    if targetCollection is not None:
        response["targetCollection"] = targetCollection
    logger.info(
        '[UPLOAD][RESULT][req:%s] completed imported=%s skipped=%s tagged=%s organized=%s rescanned=%s tagAttachSuccess=%s tagAttachFailure=%s attachedTagsByMedia=%s',
        request_id,
        imported_count,
        skipped_count,
        tagged_count,
        organized_count,
        rescanned_count,
        tag_attach_success_count,
        tag_attach_failure_count,
        _log_attached_tags_by_media(attached_tags_by_media),
    )
    return response


@router.get("/download-url/status", response_model=DownloadUrlStatusResponse)
def download_url_status(
    request: Request,
    requestId: str,
) -> DownloadUrlStatusResponse:
    request_id = requestId.strip()
    if not request_id:
        raise bad_request("requestId is required")
    store = _url_download_status_store(request)
    raw = store.get(request_id)
    if raw is None:
        return DownloadUrlStatusResponse(
            requestId=request_id,
            status="ホスト応答待ち",
        )
    return DownloadUrlStatusResponse(
        requestId=request_id,
        status=str(raw.get("status") or ""),
        total=_as_status_int(raw.get("total")),
        completed=_as_status_int(raw.get("completed")),
        success=_as_status_int(raw.get("success")),
        failed=_as_status_int(raw.get("failed")),
        skipped=_as_status_int(raw.get("skipped")),
        currentFile=raw.get("currentFile") if isinstance(raw.get("currentFile"), str) else None,
    )


@router.post("/download-url", response_model=DownloadUrlResponse)
async def download_url(
    request: Request,
    payload: DownloadUrlRequest,
) -> DownloadUrlResponse:
    request_id = (payload.requestId or "").strip() or secrets.token_hex(8)
    _set_url_download_status(
        request,
        request_id,
        status="ホストがURLダウンロードを受信しました",
    )
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
        prefer_hitomi_original=payload.preferHitomiOriginal,
    )
    if not options.has_any_source(source_url):
        raise bad_request("Provide a URL, URL list file, or favorites condition")

    settings = request.app.state.settings
    folder_path = os.path.normpath(payload.folderRaw)
    if not os.path.isdir(folder_path):
        raise bad_request(f"Destination folder does not exist: {payload.folderRaw}")
    if settings.media_roots and not any(_is_inside_root(folder_path, root) for root in settings.media_roots):
        raise bad_request("folderRaw must be inside configured media roots")

    staged_entries: list[tuple[str, str]] = []
    staging_dir = _create_hidden_download_staging_dir(folder_path)

    try:
        async def on_download_event(event: dict[str, object]) -> None:
            _set_url_download_status(
                request,
                request_id,
                status=str(event.get("status") or "ダウンロード中"),
                total=_as_status_int(event.get("total")),
                completed=_as_status_int(event.get("completed")),
                success=_as_status_int(event.get("success")),
                failed=_as_status_int(event.get("failed")),
                skipped=_as_status_int(event.get("skipped")),
                current_file=event.get("current_file") if isinstance(event.get("current_file"), str) else None,
            )

        download_result = await request.app.state.url_download_service.download_url(
            source_url=source_url,
            destination_folder=staging_dir,
            options=options,
            on_event=on_download_event,
        )
        _set_url_download_status(
            request,
            request_id,
            status="ホスト側で取り込み準備中",
            total=download_result.total_count,
            completed=download_result.completed_count,
            success=download_result.imported_count,
            failed=download_result.failed_count,
            skipped=download_result.skipped_count,
            current_file=download_result.current_file,
        )
        if download_result.imported_count > 0:
            staged_entries = _stage_download_url_imports(
                folder_path=folder_path,
                staging_dir=staging_dir,
                overwrite_existing=payload.overwrite,
                prefer_gif_collections=True,
            )
    except UrlDownloadError as error:
        _set_url_download_status(request, request_id, status=f"失敗: {error}")
        raise bad_request(str(error)) from error
    finally:
        shutil.rmtree(staging_dir, ignore_errors=True)

    tagged_count = 0
    organized_count = 0
    rescanned_count = 0

    if staged_entries:
        index_service = request.app.state.index_service
        metadata_store = request.app.state.metadata_store
        common_tags = _build_import_tags(
            artist_tag=payload.artistTag,
            series_tag=payload.seriesTag,
            free_tags=payload.freeTags,
            character_tags=payload.characterTags,
        )
        source_urls = _collect_source_urls(payload.url, payload.urls)
        rescanned_count = index_service.scan_folder(folder_path)

        resolved_entries: list[tuple[str, list[dict[str, str]]]] = []
        imported_media_ids: list[str] = []
        unresolved_paths: list[str] = []
        has_any_tags = bool(common_tags)
        should_organize_after_import = True
        for saved_path, relative_path_hint in staged_entries:
            inferred_tags = []
            is_gif_collection = _is_gif_collection_path(saved_path)
            hitomi_metadata = _lookup_hitomi_metadata_for_relative_path(
                relative_path_hint,
                download_result.hitomi_metadata_by_relative_path,
            )
            inferred_candidates = build_inferred_import_tags(
                relative_path=relative_path_hint,
                source_urls=source_urls,
                hitomi_metadata=hitomi_metadata,
            )
            if normalized_extension(saved_path) == ".pdf" or is_gif_collection:
                inferred_tags = filter_hitomi_pdf_auto_tags(inferred_candidates)
            else:
                inferred_tags = filter_supported_url_import_image_tags(
                    inferred_candidates
                )
            if is_gif_collection:
                inferred_tags = _merge_import_tags(
                    inferred_tags,
                    [{"category": "mediaType", "name": "GIF"}],
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

        if unresolved_paths and (has_any_tags or should_organize_after_import):
            failed_name = os.path.basename(unresolved_paths[0])
            raise bad_request(f"Failed to resolve media identity after save: {failed_name}")

        for media_id, merged_tags in resolved_entries:
            if not merged_tags:
                continue
            metadata_store.add_tags_to_media(media_id, merged_tags)
            tagged_count += 1

        if should_organize_after_import and imported_media_ids:
            organized = metadata_store.organize_media_by_tags(
                library_root=folder_path,
                media_ids=imported_media_ids,
            )
            organized_count = len(organized)
            rescanned_count = index_service.scan_folder(folder_path)

    _set_url_download_status(
        request,
        request_id,
        status="完了",
        total=download_result.total_count,
        completed=download_result.completed_count,
        success=download_result.imported_count,
        failed=download_result.failed_count,
        skipped=download_result.skipped_count,
        current_file=download_result.current_file,
    )
    return DownloadUrlResponse(
        importedCount=download_result.imported_count,
        skippedCount=download_result.skipped_count,
        failedCount=download_result.failed_count,
        taggedCount=tagged_count,
        organizedCount=organized_count,
        rescannedCount=rescanned_count,
        logLines=download_result.log_lines[-20:],
        targetCollection=payload.targetCollection,
    )


@router.post("/rename", response_model=MessageResponse)
def apply_rename(request: Request, payload: RenameRequest) -> MessageResponse:
    before = payload.before
    after = payload.after
    old_path = payload.oldPath or (before.path if before else None)
    new_path = payload.newPath or (after.path if after else None)
    thumbnail_service = getattr(request.app.state, "thumbnail_service", None)
    if thumbnail_service is not None and old_path:
        close_cached_pdf_documents = getattr(
            thumbnail_service,
            "close_cached_pdf_documents",
            None,
        )
        if close_cached_pdf_documents is not None:
            close_cached_pdf_documents([old_path])
    try:
        request.app.state.metadata_store.apply_rename(
            old_media_id=payload.oldMediaId or (before.mediaId if before else None),
            new_media_id=payload.newMediaId or (after.mediaId if after else None),
            old_path=old_path,
            new_path=new_path,
        )
    except ApiError:
        raise
    except Exception as error:
        logger.exception("[rename] metadata update failed old=%s new=%s", old_path, new_path)
        renamed_on_disk = (
            bool(old_path)
            and bool(new_path)
            and not os.path.exists(old_path)
            and os.path.exists(new_path)
        )
        if not renamed_on_disk:
            raise server_error(f"名前の変更に失敗しました: {error}") from error

        index_service = getattr(request.app.state, "index_service", None)
        try:
            if index_service is not None:
                index_service.scan_folder(os.path.dirname(new_path))
        except Exception:
            logger.exception("[rename] rescan after metadata failure also failed: %s", new_path)
        logger.warning("[rename] completed on disk and recovered with a rescan: %s", new_path)
    return MessageResponse(message="Rename completed")


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
    thumbnail_service = getattr(request.app.state, "thumbnail_service", None)
    if thumbnail_service is not None:
        close_cached_pdf_documents = getattr(
            thumbnail_service,
            "close_cached_pdf_documents",
            None,
        )
        if close_cached_pdf_documents is not None:
            close_cached_pdf_documents(
                [
                    str(item.get("path") or "")
                    for item in items
                    if str(item.get("path") or "").strip()
                ]
            )
    deleted = request.app.state.metadata_store.apply_delete(
        items=items,
        hard_delete=payload.hardDelete,
    )
    return MessageResponse(message=f"Deleted {deleted} items")


def _normalize_upload_request_id(raw: str | None) -> str:
    trimmed = str(raw or '').strip()
    if trimmed:
        return trimmed
    return f"up-{secrets.token_hex(4)}"


def _log_scalar(value: object | None) -> str:
    if value is None:
        return 'null'
    return json.dumps(str(value), ensure_ascii=False)


def _log_string_list(values: list[str]) -> str:
    if not values:
        return '[]'
    return '[' + ', '.join(_log_scalar(value) for value in values) + ']'


def _log_tag_list(tags: list[dict[str, str]]) -> str:
    if not tags:
        return '[]'
    out: list[str] = []
    for tag in tags:
        category = str(tag.get('category') or '').strip()
        name = str(tag.get('name') or '').strip()
        out.append(f'{category}:{name}')
    return _log_string_list(out)


def _log_tag_groups(tag_groups: list[list[dict[str, str]]]) -> str:
    if not tag_groups:
        return '[]'
    return '[' + ', '.join(_log_tag_list(group) for group in tag_groups) + ']'


def _log_category_values(tags: list[dict[str, str]], category: str) -> str:
    values = [str(tag.get('name') or '').strip() for tag in tags if str(tag.get('category') or '').strip() == category and str(tag.get('name') or '').strip()]
    return _log_string_list(values)


def _log_attached_tags_by_media(attached_tags_by_media: dict[str, list[str]]) -> str:
    if not attached_tags_by_media:
        return '{}'
    entries: list[str] = []
    for media_id, tags in attached_tags_by_media.items():
        entries.append(f'{_log_scalar(media_id)}:{_log_string_list(tags)}')
    return '{' + ', '.join(entries) + '}'


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



def _resolve_form_string(value: str | object) -> str:
    if isinstance(value, str):
        return value
    default = getattr(value, "default", "")
    return default if isinstance(default, str) else ""


def _resolve_optional_form_string(value: str | None | object) -> str | None:
    if value is None or isinstance(value, str):
        return value
    default = getattr(value, "default", None)
    return default if isinstance(default, str) or default is None else None


def _resolve_form_bool(value: bool | object, *, default: bool) -> bool:
    if isinstance(value, bool):
        return value
    fallback = getattr(value, "default", default)
    return fallback if isinstance(fallback, bool) else default


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
        raise bad_request(f"{field_name} must be a JSON array") from error

    if not isinstance(value, list):
        raise bad_request(f"{field_name} must be a JSON array")

    out: list[str] = []
    for entry in value:
        if not isinstance(entry, str):
            raise bad_request(f"Each entry in {field_name} must be a string")
        trimmed = entry.strip()
        if trimmed or preserve_empty:
            out.append(trimmed)
    return out


def _collect_source_urls(primary_url: str, extra_urls: list[str]) -> list[str]:
    urls: list[str] = []
    seen: set[str] = set()
    for raw in [primary_url, *extra_urls]:
        value = str(raw or "")
        matched_urls = re.findall(r"https?://[^\s,]+", value, flags=re.IGNORECASE)
        segments = matched_urls or re.split(r"[\s,]+", value)
        for chunk in segments:
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


def _same_file(source_path: str, target_path: str) -> bool:
    normalized_source = os.path.normcase(os.path.normpath(source_path))
    normalized_target = os.path.normcase(os.path.normpath(target_path))
    if normalized_source == normalized_target:
        return True

    try:
        return os.path.samefile(source_path, target_path)
    except OSError:
        pass

    if not os.path.isfile(source_path) or not os.path.isfile(target_path):
        return False

    try:
        source_stat = os.stat(source_path)
        target_stat = os.stat(target_path)
    except OSError:
        return False

    return (
        int(source_stat.st_size) == int(target_stat.st_size)
        and int(source_stat.st_mtime * 1000) == int(target_stat.st_mtime * 1000)
    )


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


async def _save_upload_file_atomic(
    upload: UploadFile,
    destination: str,
    *,
    request_id: str,
    index: int,
) -> None:
    destination_path = Path(destination)
    destination_path.parent.mkdir(parents=True, exist_ok=True)

    temp_path: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            delete=False,
            dir=str(destination_path.parent),
            prefix=f".{destination_path.name}.upload-",
            suffix=".part",
        ) as handle:
            temp_path = handle.name
            logger.info(
                '[UPLOAD][SERVER][req:%s] temp_save_start index=%s temp=%s destination=%s',
                request_id,
                index,
                _log_scalar(temp_path),
                _log_scalar(destination),
            )
            while True:
                chunk = await upload.read(1024 * 1024)
                if not chunk:
                    break
                handle.write(chunk)
            handle.flush()
            os.fsync(handle.fileno())

        os.replace(temp_path, destination)
        logger.info(
            '[UPLOAD][SERVER][req:%s] temp_save_finish index=%s temp=%s destination=%s',
            request_id,
            index,
            _log_scalar(temp_path),
            _log_scalar(destination),
        )
    except Exception:
        logger.exception(
            '[UPLOAD][ERROR][req:%s] temp_save_failed index=%s temp=%s destination=%s',
            request_id,
            index,
            _log_scalar(temp_path),
            _log_scalar(destination),
        )
        if temp_path:
            try:
                os.remove(temp_path)
            except OSError:
                logger.warning(
                    '[UPLOAD][SERVER][req:%s] temp_cleanup_failed index=%s temp=%s',
                    request_id,
                    index,
                    _log_scalar(temp_path),
                    exc_info=True,
                )
        raise

def _is_hidden_temp_name(name: str) -> bool:
    value = str(name or "").strip()
    return bool(value) and value not in {".", ".."} and value.startswith(".")


def _create_hidden_download_staging_dir(folder_path: str) -> str:
    return tempfile.mkdtemp(prefix=".download-url-stage-", dir=folder_path)


def _stage_download_url_imports(
    *,
    folder_path: str,
    staging_dir: str,
    overwrite_existing: bool,
    prefer_gif_collections: bool = False,
) -> list[tuple[str, str]]:
    staged_media_paths = _collect_media_paths(staging_dir, include_hidden=True)
    preferred_paths = _prefer_generated_pdf_import_paths(
        staging_dir,
        sorted(staged_media_paths),
    )
    if prefer_gif_collections:
        preferred_paths = _prefer_gif_collection_import_paths(
            staging_dir,
            preferred_paths,
        )
    flattened_entries = _flatten_imported_media_paths(staging_dir, preferred_paths)
    saved_entries = _move_staged_media_entries_to_library(
        folder_path=folder_path,
        flattened_entries=flattened_entries,
    )
    _remove_empty_dirs(staging_dir)
    _move_remaining_stage_items_to_folder(
        staging_dir=staging_dir,
        folder_path=folder_path,
        overwrite_existing=overwrite_existing,
    )
    return saved_entries


def _move_staged_media_entries_to_library(
    *,
    folder_path: str,
    flattened_entries: list[tuple[str, str]],
) -> list[tuple[str, str]]:
    saved_entries: list[tuple[str, str]] = []

    for source_path, relative_hint in flattened_entries:
        file_name = os.path.basename(source_path)
        target_path = os.path.normpath(os.path.join(folder_path, file_name))
        if os.path.exists(target_path):
            if os.path.isfile(source_path) and _same_file(source_path, target_path):
                logger.info('[MOVE] skipped same-file old=%s new=%s', source_path, target_path)
                try:
                    os.remove(source_path)
                except OSError:
                    pass
                saved_entries.append((os.path.normpath(target_path), relative_hint))
                continue
            if os.path.isdir(source_path) and os.path.isdir(target_path):
                _merge_staged_path(
                    source_path=source_path,
                    target_path=target_path,
                    overwrite_existing=False,
                )
                saved_entries.append((os.path.normpath(target_path), relative_hint))
                continue
            replacement_path = _resolve_available_import_target_path(target_path)
            logger.info(
                '[MOVE] renamed duplicate import source=%s target=%s replacement=%s',
                source_path,
                target_path,
                replacement_path,
            )
            target_path = replacement_path

        shutil.move(source_path, target_path)
        saved_entries.append((os.path.normpath(target_path), relative_hint))

    return saved_entries


def _move_remaining_stage_items_to_folder(
    *,
    staging_dir: str,
    folder_path: str,
    overwrite_existing: bool,
) -> None:
    for child_name in os.listdir(staging_dir):
        source_path = os.path.join(staging_dir, child_name)
        target_path = os.path.join(folder_path, child_name)
        _merge_staged_path(
            source_path=source_path,
            target_path=target_path,
            overwrite_existing=overwrite_existing,
        )


def _merge_staged_path(
    *,
    source_path: str,
    target_path: str,
    overwrite_existing: bool,
) -> None:
    if not os.path.exists(source_path):
        return

    if not os.path.exists(target_path):
        shutil.move(source_path, target_path)
        return

    if os.path.isdir(source_path):
        if not os.path.isdir(target_path):
            raise bad_request('Duplicate file or folder name already exists')
        for child_name in os.listdir(source_path):
            _merge_staged_path(
                source_path=os.path.join(source_path, child_name),
                target_path=os.path.join(target_path, child_name),
                overwrite_existing=overwrite_existing,
            )
        try:
            if not os.listdir(source_path):
                os.rmdir(source_path)
        except OSError:
            pass
        return

    if os.path.isdir(target_path):
        raise bad_request('Duplicate file or folder name already exists')

    if _same_file(source_path, target_path):
        try:
            os.remove(source_path)
        except OSError:
            pass
        return

    if overwrite_existing:
        os.replace(source_path, target_path)
        return

    try:
        os.remove(source_path)
    except OSError:
        pass


def _collect_media_paths(folder_path: str, *, include_hidden: bool = False) -> set[str]:
    found: set[str] = set()
    for base, dirs, files in os.walk(folder_path):
        if not include_hidden:
            dirs[:] = [
                directory_name
                for directory_name in dirs
                if not _is_hidden_temp_name(directory_name)
            ]
        for file_name in files:
            if not include_hidden and _is_hidden_temp_name(file_name):
                continue
            if not is_supported_media_extension(normalized_extension(file_name)):
                continue
            found.add(os.path.normpath(os.path.join(base, file_name)))
    return found


def _build_host_pdf_file_name(
    *,
    host_pdf_name_hint: str | None,
    source_relative_paths: list[str],
    original_display_names: list[str],
) -> str:
    candidates = [
        host_pdf_name_hint or "",
        _derive_host_pdf_name_from_source_paths(source_relative_paths),
        _derive_host_pdf_name_from_original_names(original_display_names),
        "imported_images",
    ]
    for candidate in candidates:
        sanitized = _sanitize_upload_display_name(candidate)
        if not sanitized:
            continue
        stem = Path(sanitized).stem if normalized_extension(sanitized) else sanitized
        stem = stem.strip()
        if stem:
            return f"{stem}.pdf"
    return "imported_images.pdf"


def _derive_host_pdf_name_from_source_paths(source_relative_paths: list[str]) -> str:
    normalized_paths = [
        str(path or "").strip().replace("\\", "/")
        for path in source_relative_paths
        if str(path or "").strip()
    ]
    directory_paths = [
        posixpath.dirname(path)
        for path in normalized_paths
        if posixpath.dirname(path) not in {"", ".", "/"}
    ]
    if not directory_paths:
        return ""
    try:
        common_dir = posixpath.commonpath(directory_paths)
    except ValueError:
        common_dir = directory_paths[0]
    base_name = posixpath.basename(common_dir.rstrip("/"))
    return base_name.strip()


def _derive_host_pdf_name_from_original_names(original_display_names: list[str]) -> str:
    normalized_names = [
        _sanitize_upload_display_name(name)
        for name in original_display_names
        if _sanitize_upload_display_name(name)
    ]
    if len(normalized_names) != 1:
        return ""
    return Path(normalized_names[0]).stem.strip()


def _convert_uploaded_images_to_pdf(image_paths: list[str], destination: str) -> None:
    if not image_paths:
        raise bad_request("No images were provided for host PDF conversion")

    folder_path = os.path.dirname(destination)
    os.makedirs(folder_path, exist_ok=True)
    fd, temp_pdf_path = tempfile.mkstemp(
        prefix=".upload-host-pdf-",
        suffix=".pdf",
        dir=folder_path,
    )
    os.close(fd)

    images: list[Image.Image] = []
    try:
        for image_path in image_paths:
            try:
                with Image.open(image_path) as opened:
                    prepared = ImageOps.exif_transpose(opened)
                    if prepared.mode != "RGB":
                        prepared = prepared.convert("RGB")
                    else:
                        prepared = prepared.copy()
                    images.append(prepared)
            except UnidentifiedImageError as error:
                raise bad_request(
                    f"Host PDF conversion could not read image: {os.path.basename(image_path)}"
                ) from error

        first, rest = images[0], images[1:]
        first.save(temp_pdf_path, "PDF", resolution=100.0, save_all=True, append_images=rest)
        os.replace(temp_pdf_path, destination)
    finally:
        for image in images:
            try:
                image.close()
            except Exception:
                pass
        if os.path.exists(temp_pdf_path):
            try:
                os.remove(temp_pdf_path)
            except OSError:
                pass


def _prefer_generated_pdf_import_paths(
    folder_path: str,
    imported_paths: list[str],
) -> list[str]:
    normalized_paths = [os.path.normpath(path) for path in imported_paths]
    pdf_relative_paths = {
        _normalized_relative_path(path, folder_path)
        for path in normalized_paths
        if normalized_extension(path) == ".pdf"
    }
    if not pdf_relative_paths:
        return normalized_paths

    preferred: list[str] = []
    dropped: list[str] = []
    for path in normalized_paths:
        if _is_generated_pdf_source_image(path, folder_path, pdf_relative_paths):
            dropped.append(path)
            continue
        preferred.append(path)

    for path in dropped:
        try:
            os.remove(path)
        except OSError:
            continue
    if dropped:
        _remove_empty_dirs(folder_path)
    return preferred


def _is_generated_pdf_source_image(
    path: str,
    folder_path: str,
    pdf_relative_paths: set[str],
) -> bool:
    if normalized_extension(path) == ".pdf":
        return False

    relative_path = _normalized_relative_path(path, folder_path)
    parent_dir = posixpath.dirname(relative_path)
    if not parent_dir or parent_dir == ".":
        return False

    gallery_folder = posixpath.basename(parent_dir)
    creator_dir = posixpath.dirname(parent_dir)
    if not gallery_folder or gallery_folder == "." or creator_dir in {"", "."}:
        return False

    candidate_names = {gallery_folder}
    stripped_gallery_folder = strip_hitomi_download_prefix(gallery_folder)
    if stripped_gallery_folder:
        candidate_names.add(stripped_gallery_folder)

    return any(
        posixpath.normpath(posixpath.join(creator_dir, f"{candidate_name}.pdf"))
        in pdf_relative_paths
        for candidate_name in candidate_names
    )


def _prefer_gif_collection_import_paths(
    folder_path: str,
    imported_paths: list[str],
) -> list[str]:
    normalized_root = os.path.normcase(os.path.normpath(folder_path))
    gif_parent_counts: dict[str, int] = {}
    for path in imported_paths:
        normalized_path = os.path.normpath(path)
        if not _is_gif_collection_member_path(normalized_path):
            continue
        parent = os.path.dirname(normalized_path)
        if os.path.normcase(parent) == normalized_root:
            continue
        gif_parent_counts[parent] = gif_parent_counts.get(parent, 0) + 1
    gif_parents = {
        parent for parent, count in gif_parent_counts.items() if count > 1
    }
    if not gif_parents:
        return imported_paths

    preferred: list[str] = []
    for path in imported_paths:
        normalized_path = os.path.normpath(path)
        if os.path.dirname(normalized_path) in gif_parents:
            continue
        preferred.append(normalized_path)
    preferred.extend(sorted(gif_parents))
    return preferred


def _normalized_relative_path(path: str, folder_path: str) -> str:
    return os.path.relpath(path, folder_path).replace("\\", "/")


def _collapse_repeated_numeric_suffixes(stem: str) -> str:
    value = str(stem or "").strip()
    if not value:
        return value

    suffixes: list[str] = []
    while True:
        match = re.search(r" \((\d+)\)$", value)
        if match is None:
            break
        suffixes.append(match.group(1))
        value = value[: match.start()]

    if len(suffixes) < 2:
        return stem
    if any(suffix != suffixes[0] for suffix in suffixes):
        return stem
    if not value.strip():
        return stem
    return f"{value} ({suffixes[0]})"


def _normalized_import_file_name(file_name: str) -> str:
    path = Path(str(file_name or ""))
    collapsed_stem = _collapse_repeated_numeric_suffixes(path.stem)
    if collapsed_stem == path.stem:
        return path.name
    return f"{collapsed_stem}{path.suffix}"


def _resolve_available_import_target_path(target_path: str) -> str:
    normalized_target = os.path.normpath(target_path)
    parent_dir = os.path.dirname(normalized_target)
    stem, suffix = os.path.splitext(os.path.basename(normalized_target))

    candidate = normalized_target
    counter = 2
    while os.path.exists(candidate):
        candidate = os.path.join(parent_dir, f"{stem} ({counter}){suffix}")
        counter += 1

    return os.path.normpath(candidate)


def _replace_relative_basename(relative_path: str, file_name: str) -> str:
    normalized = str(relative_path or "").replace("\\", "/")
    parent = posixpath.dirname(normalized)
    if not parent or parent == ".":
        return file_name
    return posixpath.join(parent, file_name)


def _lookup_hitomi_metadata_for_relative_path(
    relative_path_hint: str,
    metadata_by_relative_path: dict[str, dict[str, object]],
) -> dict[str, object] | None:
    normalized = str(relative_path_hint or "").replace("\\", "/").casefold()
    if normalized:
        exact = metadata_by_relative_path.get(normalized)
        if exact is not None:
            return exact

    basename = posixpath.basename(normalized)
    if not basename:
        return None
    basename_stem = posixpath.splitext(basename)[0]
    basename_candidates = {basename, basename_stem}
    stripped_basename_stem = strip_hitomi_download_prefix(basename_stem)
    if stripped_basename_stem:
        basename_candidates.add(stripped_basename_stem.casefold())

    match: dict[str, object] | None = None
    for key, value in metadata_by_relative_path.items():
        key_basename = posixpath.basename(str(key or "").replace("\\", "/").casefold())
        key_stem = posixpath.splitext(key_basename)[0]
        key_candidates = {key_basename, key_stem}
        stripped_key_stem = strip_hitomi_download_prefix(key_stem)
        if stripped_key_stem:
            key_candidates.add(stripped_key_stem.casefold())
        if not basename_candidates.intersection(key_candidates):
            continue
        if match is not None:
            return None
        match = value
    return match


def _is_gif_collection_path(path: str) -> bool:
    if not os.path.isdir(path):
        return False
    try:
        return any(
            _is_gif_collection_member_path(os.path.join(path, file_name))
            for file_name in os.listdir(path)
        )
    except OSError:
        return False


def _is_gif_collection_member_path(path: str) -> bool:
    extension = normalized_extension(path)
    if extension == ".gif":
        return os.path.isfile(path)
    if extension != ".webp" or not os.path.isfile(path):
        return False
    try:
        with Image.open(path) as image:
            return bool(getattr(image, "is_animated", False)) or int(
                getattr(image, "n_frames", 1) or 1
            ) > 1
    except (OSError, UnidentifiedImageError):
        return False


def _flatten_imported_media_paths(
    folder_path: str,
    imported_paths: list[str],
) -> list[tuple[str, str]]:
    flattened: list[tuple[str, str]] = []

    for raw_path in imported_paths:
        source_path = os.path.normpath(raw_path)
        relative_path = os.path.relpath(source_path, folder_path).replace("\\", "/")
        file_name = _normalized_import_file_name(os.path.basename(source_path))
        if os.path.isdir(source_path):
            stripped_file_name = strip_hitomi_download_prefix(file_name)
            if stripped_file_name:
                file_name = _normalized_import_file_name(stripped_file_name)
        relative_hint = _replace_relative_basename(relative_path, file_name)
        if os.path.isdir(source_path):
            target_path = os.path.normpath(os.path.join(folder_path, file_name))
            if os.path.normcase(target_path) == os.path.normcase(source_path):
                flattened.append((source_path, relative_hint))
                continue
            if os.path.exists(target_path):
                replacement_path = _resolve_available_import_target_path(target_path)
                logger.info(
                    '[MOVE] renamed duplicate flattened import folder source=%s target=%s replacement=%s',
                    source_path,
                    target_path,
                    replacement_path,
                )
                target_path = replacement_path
            shutil.move(source_path, target_path)
            flattened.append((os.path.normpath(target_path), relative_hint))
            continue
        target_path = os.path.normpath(os.path.join(folder_path, file_name))
        if os.path.normcase(target_path) == os.path.normcase(source_path):
            flattened.append((source_path, relative_hint))
            continue
        if os.path.exists(target_path):
            if _same_file(source_path, target_path):
                logger.info('[MOVE] skipped same-file old=%s new=%s', source_path, target_path)
                try:
                    os.remove(source_path)
                except OSError:
                    pass
                flattened.append((os.path.normpath(target_path), relative_hint))
                continue
            replacement_path = _resolve_available_import_target_path(target_path)
            logger.info(
                '[MOVE] renamed duplicate flattened import source=%s target=%s replacement=%s',
                source_path,
                target_path,
                replacement_path,
            )
            target_path = replacement_path

        shutil.move(source_path, target_path)
        flattened.append((os.path.normpath(target_path), relative_hint))

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








