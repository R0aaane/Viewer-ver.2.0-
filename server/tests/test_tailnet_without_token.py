from types import SimpleNamespace
import unittest

from fastapi import Depends, FastAPI
from fastapi.testclient import TestClient

from server.services.auth_service import require_bearer_token, authenticate_connection
from server.services.private_access import PrivateAccessMiddleware


class TailnetWithoutTokenTests(unittest.TestCase):
    def app(self, enabled=True):
        app = FastAPI()
        app.state.settings = SimpleNamespace(auth_token="admin-secret", tailnet_without_token=enabled)
        app.add_middleware(PrivateAccessMiddleware,
            allowed_networks=["127.0.0.0/8", "::1/128", "100.64.0.0/10", "fd7a:115c:a1e0::/48"],
            allowed_origins=[])
        @app.get("/health", dependencies=[Depends(require_bearer_token)])
        @app.post("/host-update", dependencies=[Depends(require_bearer_token)])
        def endpoint():
            return {"ok": True}
        return app

    def test_direct_peers_and_admin_boundary(self):
        for peer in ("127.0.0.1", "::1", "100.79.164.25", "fd7a:115c:a1e0::1", "::ffff:100.79.164.25"):
            with self.subTest(peer=peer), TestClient(self.app(), client=(peer, 1234)) as client:
                self.assertEqual(client.get("/health").status_code, 200)
                self.assertEqual(client.post("/host-update").status_code, 403)
                self.assertEqual(client.post("/host-update", headers={"Authorization":"Bearer admin-secret"}).status_code, 200)
                self.assertEqual(client.get("/health", headers={"Authorization":"Bearer wrong"}).status_code, 401)

    def test_non_tailnet_forwarded_and_cross_origin_denied(self):
        for peer in ("192.168.1.2", "203.0.113.2"):
            with TestClient(self.app(), client=(peer, 1234)) as client:
                self.assertEqual(client.get("/health").status_code, 403)
        with TestClient(self.app(), client=("100.79.164.25", 1234)) as client:
            for name in ("forwarded", "x-forwarded-for", "tailscale-user-login", "tailscale-user-id"):
                self.assertEqual(client.get("/health", headers={name:"127.0.0.1"}).status_code, 401)
            self.assertEqual(client.get("/health", headers={"Origin":"https://evil.example"}).status_code, 403)
        with TestClient(self.app(False), client=("100.79.164.25", 1234)) as client:
            self.assertEqual(client.get("/health").status_code, 401)

    def test_websocket_connection_uses_same_identity_rules(self):
        app = self.app()
        connection = SimpleNamespace(app=app, headers={}, client=SimpleNamespace(host="100.79.164.25"))
        self.assertEqual(authenticate_connection(connection, None), "tailnet")
        connection.client.host = "192.168.1.2"
        self.assertIsNone(authenticate_connection(connection, None))
