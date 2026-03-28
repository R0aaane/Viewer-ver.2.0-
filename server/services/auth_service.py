from __future__ import annotations

from fastapi import Header, Request

from server.core.config import Settings
from server.core.errors import unauthorized


def get_settings_from_request(request: Request) -> Settings:
    return request.app.state.settings


def require_bearer_token(
    request: Request,
    authorization: str | None = Header(default=None),
) -> None:
    settings = get_settings_from_request(request)
    expected = settings.auth_token
    if not expected:
        return

    if authorization is None or not authorization.startswith("Bearer "):
        raise unauthorized("Bearer トークンが必要です")

    token = authorization[len("Bearer ") :].strip()
    if token != expected:
        raise unauthorized("Bearer トークンが一致しません")
