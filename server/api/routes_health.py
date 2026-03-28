from __future__ import annotations

from fastapi import APIRouter, Depends, Request

from server.models.dto import HealthResponse
from server.services.auth_service import require_bearer_token


router = APIRouter(tags=["health"])


@router.get("/health", response_model=HealthResponse, dependencies=[Depends(require_bearer_token)])
def health(request: Request) -> HealthResponse:
    settings = request.app.state.settings
    return HealthResponse(service=settings.service_name, version=settings.version)
