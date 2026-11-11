import asyncio
from contextlib import closing
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

from fastapi import Depends, FastAPI, HTTPException
import requests
from websockets.legacy.client import connect
from websockets.exceptions import ConnectionClosed

from server.api.routes_generated import router as generated_router
from server.api.routes_actions import apply_delete
from server.models.dto import DeleteRequest
from server.services.auth_service import require_bearer_token
from server.services.device_tokens import DeviceTokens
from server.services.generated_library import GeneratedLibrary
from server.services.path_access import require_library_path, local_host_admin
from server.services.private_access import PrivateAccessMiddleware
from server.tests.test_routes_generated import serve


class PrivateAccessTests(unittest.TestCase):
    def test_peer_and_origin_checks_ignore_forwarded_headers(self):
        async def probe(peer, origin=None, forwarded=None, kind="http"):
            messages = []
            async def endpoint(scope, receive, send):
                await send({"type": "http.response.start", "status": 204, "headers": []})
            middleware = PrivateAccessMiddleware(endpoint,
                ["127.0.0.0/8", "::1/128", "100.64.0.0/10", "fd7a:115c:a1e0::/48"], [])
            headers = [(b"host", b"host.example.ts.net")]
            if origin:
                headers.append((b"origin", origin.encode()))
            if forwarded:
                headers.append((b"x-forwarded-for", forwarded.encode()))
            async def receive():
                return {"type": "http.request"}
            async def send(message):
                messages.append(message)
            await middleware({"type": kind, "client": (peer, 1234), "headers": headers}, receive, send)
            return messages[0]
        for peer in ("127.0.0.1", "::1", "100.79.1.2", "fd7a:115c:a1e0::1", "::ffff:100.79.1.2"):
            self.assertEqual(asyncio.run(probe(peer))["status"], 204)
        for peer in ("192.168.1.2", "203.0.113.2"):
            self.assertEqual(asyncio.run(probe(peer, forwarded="100.79.1.2"))["status"], 403)
        self.assertEqual(asyncio.run(probe("127.0.0.1", origin="https://evil.example"))["status"], 403)
        self.assertEqual(asyncio.run(probe("127.0.0.1", origin="https://host.example.ts.net"))["status"], 204)
        self.assertEqual(asyncio.run(probe("203.0.113.2", kind="websocket"))["code"], 1008)

    def test_device_hashes_revocation_and_websocket_recheck(self):
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "output"
            source.mkdir()
            library = GeneratedLibrary(source, root / "library")
            store = DeviceTokens(root / "devices.sqlite")
            device_id, token = store.issue("phone")
            other_id, other_token = store.issue("tablet")
            self.assertEqual(DeviceTokens(store.path).verify(token), device_id)
            self.assertNotIn(token, store.path.read_bytes().decode("utf-8", errors="ignore"))
            self.assertNotIn("digest", store.list()[0])
            app = FastAPI()
            app.state.settings = SimpleNamespace(auth_token="legacy-host")
            app.state.device_tokens = store
            app.state.generated_library = library
            media = root / "media"
            media.mkdir()
            app.state.settings.media_roots = [str(media)]
            app.state.metadata_store = Mock()
            app.state.metadata_store.get_media.side_effect = lambda media_id, identity=None: {
                "fullPath": (identity or {}).get("normalizedPath", str(media / "sample.png"))}
            app.include_router(generated_router)
            @app.get("/protected", dependencies=[Depends(require_bearer_token)])
            @app.get("/items/{media_id}/download", dependencies=[Depends(require_bearer_token)])
            @app.post("/host-update/run", dependencies=[Depends(require_bearer_token)])
            def protected():
                return {"ok": True}
            with serve(app) as port:
                url = f"http://127.0.0.1:{port}"
                auth = {"Authorization": f"Bearer {token}"}
                self.assertEqual(requests.get(url + "/protected", timeout=3).status_code, 401)
                self.assertEqual(requests.get(url + "/protected", headers=auth, timeout=3).status_code, 200)
                self.assertEqual(requests.get(url + "/items/legacy-id/download", headers=auth,
                    params={"normalizedPath": str(media / "sample.png")}, timeout=3).status_code, 200)
                app.state.metadata_store.get_media.assert_called_with("legacy-id", identity={"aliases": [], "normalizedPath": str(media / "sample.png")})
                self.assertEqual(requests.get(url + "/items/legacy-id/download", headers=auth,
                    params={"normalizedPath": str(root / "secret.txt")}, timeout=3).status_code, 403)
                self.assertEqual(requests.post(url + "/host-update/run", headers=auth, timeout=3).status_code, 403)
                self.assertEqual(requests.get(url + "/protected", headers={"Authorization": "Bearer legacy-host"}, timeout=3).status_code, 200)

                async def revoke_open_socket():
                    async with connect(f"ws://127.0.0.1:{port}/generated/events/ws", extra_headers=auth) as socket:
                        store.revoke(device_id)
                        with self.assertRaises(ConnectionClosed):
                            await asyncio.wait_for(socket.recv(), 6)
                asyncio.run(revoke_open_socket())
                self.assertEqual(requests.get(url + "/protected", headers=auth, timeout=3).status_code, 401)
                # A device credential cannot become a non-revocable host secret.
                app.state.settings.auth_token = token
                self.assertEqual(requests.get(url + "/protected", headers=auth, timeout=3).status_code, 401)
                self.assertEqual(store.verify(other_token), other_id)
                store.revoke(other_id)
                app.state.settings.auth_token = None
                self.assertEqual(requests.get(url + "/protected", timeout=3).status_code, 401)
                app.state.device_tokens = DeviceTokens(root / "empty.sqlite")
                self.assertEqual(requests.get(url + "/protected", timeout=3).status_code, 503)

    def test_paths_and_whole_delete_batch_are_checked_before_mutation(self):
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            allowed = root / "library"
            allowed.mkdir()
            metadata = Mock()
            metadata.get_media.return_value = {"fullPath": str(root / "secret.txt")}
            request = SimpleNamespace(state=SimpleNamespace(auth_identity="device"),
                client=SimpleNamespace(host="100.79.1.2"), app=SimpleNamespace(state=SimpleNamespace(
                    settings=SimpleNamespace(media_roots=[str(allowed)]), metadata_store=metadata)))
            require_library_path(request, str(allowed / "photo.png"))
            for path in (str(root / "secret.txt"), str(allowed / ".." / "secret.txt"),
                         str(root / "library-extra" / "secret.txt"), str(allowed)):
                with self.assertRaises(HTTPException):
                    require_library_path(request, path)
            payload = DeleteRequest(items=[{"path": str(allowed / "good.png")}, {"mediaId": "outside"}])
            with self.assertRaises(HTTPException):
                apply_delete(request, payload)
            metadata.apply_delete.assert_not_called()

    def test_symlink_cannot_escape_the_library(self):
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            allowed = root / "library"
            allowed.mkdir()
            outside = root / "secret"
            outside.mkdir()
            try:
                (allowed / "link").symlink_to(outside, target_is_directory=True)
            except OSError:
                self.skipTest("Symlink creation requires Windows developer mode")
            request = SimpleNamespace(state=SimpleNamespace(auth_identity="device"), client=None,
                app=SimpleNamespace(state=SimpleNamespace(settings=SimpleNamespace(media_roots=[str(allowed)]))))
            with self.assertRaises(HTTPException):
                require_library_path(request, str(allowed / "link" / "secret.txt"))

    def test_reverse_proxy_loopback_is_not_local_host_administration(self):
        request = SimpleNamespace(state=SimpleNamespace(auth_identity="host"),
            client=SimpleNamespace(host="127.0.0.1"), headers={"x-forwarded-for": "100.79.1.2"},
            url=SimpleNamespace(hostname="localhost"))
        self.assertFalse(local_host_admin(request))
        request.headers = {}
        request.url.hostname = "toybox.example.ts.net"
        self.assertFalse(local_host_admin(request))
        request.url.hostname = "127.0.0.1"
        self.assertTrue(local_host_admin(request))
