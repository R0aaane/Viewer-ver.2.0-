from ipaddress import ip_address
from pathlib import Path

from fastapi import HTTPException


def local_host_admin(request):
    if getattr(getattr(request, "state", None), "auth_identity", None) != "host" or request.client is None:
        return False
    # Serve forwards to loopback. A proxied request still has remote privileges.
    if any(name in request.headers for name in ("x-forwarded-for", "forwarded", "tailscale-user-login", "tailscale-user-id")):
        return False
    if request.url.hostname not in ("127.0.0.1", "localhost", "::1"):
        return False
    try:
        return ip_address(request.client.host).is_loopback
    except ValueError:
        return False


def require_library_path(request, path, *, allow_root=False):
    # Internal callers of route functions retain their existing service contract.
    if getattr(getattr(request, "state", None), "auth_identity", None) is None or local_host_admin(request):
        return
    if not path or not Path(path).is_absolute():
        raise HTTPException(403, "An absolute path within the configured library is required")
    target = Path(path).resolve()
    for raw in request.app.state.settings.media_roots:
        root = Path(raw).resolve()
        if target.is_relative_to(root) and (allow_root or target != root):
            return
    raise HTTPException(403, "Path is outside the configured library")


def require_media_path(request, media_id, *, identity=None, allow_missing=False):
    if media_id and getattr(getattr(request, "state", None), "auth_identity", None) is not None:
        try:
            record = request.app.state.metadata_store.get_media(media_id, identity=identity)
        except HTTPException as exc:
            if allow_missing and exc.status_code == 404:
                return
            raise
        require_library_path(request, record["fullPath"])
