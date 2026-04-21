from __future__ import annotations

import re

from fastapi import APIRouter, Depends, Request
from fastapi.responses import FileResponse

from server.core.errors import not_found
from server.models.dto import HealthResponse
from server.services.auth_service import require_bearer_token
from server.services.app_update_store import (
    app_update_file_path,
    load_app_update_info,
    update_download_path,
)


router = APIRouter(tags=["health"])


@router.get("/health", response_model=HealthResponse, dependencies=[Depends(require_bearer_token)])
def health(request: Request) -> HealthResponse:
    settings = request.app.state.settings
    client_versions = sorted(getattr(request.app.state, "client_app_versions", set()))
    update_info = load_app_update_info(settings)
    configured_update_version = getattr(settings, "update_version", None)
    update_version = _select_update_version(
        uploaded_version=update_info.version if update_info else None,
        configured_version=configured_update_version,
    )
    update_url = (
        update_download_path(update_info)
        if update_info is not None and update_version == update_info.version
        else getattr(settings, "update_url", None)
    )
    latest_known_version = _latest_version([settings.version, update_version, *client_versions])
    return HealthResponse(
        service=settings.service_name,
        version=settings.version,
        latestKnownVersion=latest_known_version,
        clientVersions=client_versions,
        updateVersion=update_version,
        updateUrl=update_url,
    )


@router.get("/app-updates/{file_name}")
def download_app_update(request: Request, file_name: str) -> FileResponse:
    info = load_app_update_info(request.app.state.settings)
    if info is None or info.file_name != file_name:
        raise not_found("update file was not found")
    path = app_update_file_path(request.app.state.settings, info)
    if not path.is_file():
        raise not_found("update file was not found")
    return FileResponse(path, filename=info.original_file_name or info.file_name)


def _select_update_version(
    *,
    uploaded_version: str | None,
    configured_version: str | None,
) -> str | None:
    return _latest_version([uploaded_version, configured_version])


def _latest_version(values: list[str]) -> str | None:
    cleaned = [value.strip() for value in values if value and value.strip()]
    if not cleaned:
        return None
    return max(cleaned, key=lambda value: (_version_numbers(value), value))


def _version_numbers(value: str) -> tuple[int, ...]:
    return tuple(int(part) for part in re.findall(r"\d+", value))
