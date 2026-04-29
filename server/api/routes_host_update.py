from __future__ import annotations

from pathlib import Path

from fastapi import APIRouter, Body, Depends, Request

from server.services.auth_service import require_bearer_token
from server.services.host_update_service import load_host_update_status, start_host_update


router = APIRouter(tags=["host-update"], dependencies=[Depends(require_bearer_token)])
project_root = Path(__file__).resolve().parents[2]


@router.post("/host-update/run")
def run_host_update(
    request: Request,
    payload: dict[str, object] | None = Body(default=None),
) -> dict[str, object]:
    return start_host_update(request.app.state.settings, project_root, payload or {})


@router.get("/host-update/status")
def host_update_status(request: Request) -> dict[str, object]:
    return load_host_update_status(request.app.state.settings)
