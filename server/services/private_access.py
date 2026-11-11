"""Check the actual peer address for HTTP and WebSocket connections."""
from ipaddress import ip_address, ip_network
from urllib.parse import urlsplit

from starlette.datastructures import Headers
from starlette.responses import JSONResponse


class PrivateAccessMiddleware:
    def __init__(self, app, allowed_networks, allowed_origins):
        self.app = app
        self.networks = [ip_network(value, strict=False) for value in allowed_networks]
        self.origins = {value.rstrip("/") for value in allowed_origins if value != "*"}

    async def __call__(self, scope, receive, send):
        if scope["type"] not in ("http", "websocket"):
            return await self.app(scope, receive, send)
        headers = Headers(scope=scope)
        try:
            peer = ip_address(scope.get("client", ("", 0))[0])
            peer = getattr(peer, "ipv4_mapped", None) or peer
            allowed = any(peer in network for network in self.networks)
        except (ValueError, TypeError):
            allowed = False
        origin = headers.get("origin")
        if origin:
            parsed = urlsplit(origin)
            same_host = parsed.scheme in ("http", "https") and parsed.netloc.lower() == headers.get("host", "").lower()
            allowed = allowed and (same_host or origin.rstrip("/") in self.origins)
        if not allowed:
            if scope["type"] == "websocket":
                await send({"type": "websocket.close", "code": 1008})
            else:
                await JSONResponse({"detail": "Private network access required"}, status_code=403)(scope, receive, send)
            return

        async def secured_send(message):
            if message["type"] == "http.response.start":
                response_headers = list(message.get("headers", []))
                response_headers.extend([(b"referrer-policy", b"no-referrer"),
                                         (b"x-content-type-options", b"nosniff")])
                if headers.get("authorization"):
                    response_headers = [(k, v) for k, v in response_headers if k.lower() != b"cache-control"]
                    response_headers.append((b"cache-control", b"no-store"))
                message = dict(message, headers=response_headers)
            await send(message)
        await self.app(scope, receive, secured_send)
