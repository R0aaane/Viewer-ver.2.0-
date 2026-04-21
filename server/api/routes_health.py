from __future__ import annotations

import re

from fastapi import APIRouter, Depends, Request

from server.models.dto import HealthResponse
from server.services.auth_service import require_bearer_token


router = APIRouter(tags=["health"])


@router.get("/health", response_model=HealthResponse, dependencies=[Depends(require_bearer_token)])
def health(request: Request) -> HealthResponse:
    settings = request.app.state.settings
    client_versions = sorted(getattr(request.app.state, "client_app_versions", set()))
    update_version = getattr(settings, "update_version", None)
    latest_known_version = _latest_version([settings.version, update_version, *client_versions])
    return HealthResponse(
        service=settings.service_name,
        version=settings.version,
        latestKnownVersion=latest_known_version,
        clientVersions=client_versions,
        updateVersion=update_version,
        updateUrl=getattr(settings, "update_url", None),
    )


def _latest_version(values: list[str]) -> str | None:
    cleaned = [value.strip() for value in values if value and value.strip()]
    if not cleaned:
        return None
    return max(cleaned, key=lambda value: (_version_numbers(value), value))


def _version_numbers(value: str) -> tuple[int, ...]:
    return tuple(int(part) for part in re.findall(r"\d+", value))
