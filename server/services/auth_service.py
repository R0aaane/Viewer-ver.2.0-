from __future__ import annotations

import hmac
from fastapi import Header, Request, HTTPException

from server.core.config import Settings
from server.core.errors import unauthorized


def get_settings_from_request(request: Request) -> Settings:
    return request.app.state.settings


def authentication_configured(state):
    devices = getattr(state, "device_tokens", None)
    return bool(state.settings.auth_token or (devices and devices.configured()))


def authenticate(state, authorization):
    if not authorization or not authorization.startswith("Bearer "):
        return None
    token = authorization[7:].strip()
    expected = state.settings.auth_token
    if expected and not expected.startswith("pv1.") and hmac.compare_digest(token.encode(), expected.encode()):
        return "host"
    devices = getattr(state, "device_tokens", None)
    return devices.verify(token) if devices else None


def require_bearer_token(
    request: Request,
    authorization: str | None = Header(default=None),
) -> None:
    if not authentication_configured(request.app.state):
        raise HTTPException(503, "ホスト側で認証トークンを設定してください")
    identity = authenticate(request.app.state, authorization)
    if identity is None:
        raise unauthorized("Bearer トークンが一致しません")
    request.state.auth_identity = identity
    if (request.path_params.get("media_id") and not request.url.path.startswith("/generated/")
            and (request.method == "GET" or "/pdf-edit" in request.url.path)):
        from server.api.routes_media import _identity_from_query
        from server.services.path_access import require_media_path
        require_media_path(request, request.path_params["media_id"], identity=_identity_from_query(request))
    if identity != "host" and (request.url.path.startswith("/host-update")
                               or request.url.path == "/app-update/upload"):
        raise HTTPException(403, "Host administration requires the host credential")
