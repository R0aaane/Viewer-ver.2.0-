from __future__ import annotations

import hmac
from ipaddress import ip_address, ip_network
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


def authenticate_connection(connection, authorization):
    if authorization:
        return authenticate(connection.app.state, authorization)
    if not getattr(connection.app.state.settings, "tailnet_without_token", False):
        return None
    if any(name in connection.headers for name in
           ("forwarded", "x-forwarded-for", "tailscale-user-login", "tailscale-user-id")):
        return None
    try:
        peer = ip_address(connection.client.host)
        peer = getattr(peer, "ipv4_mapped", None) or peer
        if (peer.is_loopback or peer in ip_network("100.64.0.0/10")
                or peer in ip_network("fd7a:115c:a1e0::/48")):
            return "tailnet"
    except (ValueError, AttributeError):
        pass
    return None


def require_bearer_token(
    request: Request,
    authorization: str | None = Header(default=None),
) -> None:
    if not authentication_configured(request.app.state) and not getattr(request.app.state.settings, "tailnet_without_token", False):
        raise HTTPException(503, "ホスト側で認証トークンを設定してください")
    identity = authenticate_connection(request, authorization)
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
