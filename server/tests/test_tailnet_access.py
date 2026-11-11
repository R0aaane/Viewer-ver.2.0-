"""Opt-in HTTPS/WS smoke test against this host's actual Tailscale Serve endpoint."""
import asyncio
from dataclasses import replace
import os
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

import requests
from websockets.legacy.client import connect
from websockets.exceptions import ConnectionClosed

from server import main
from server.services.device_tokens import DeviceTokens
from server.tests.test_routes_generated import serve


@unittest.skipUnless(os.getenv("MEDIA_SERVER_TEST_TAILNET_URL"), "Opt-in tailnet smoke test")
class TailnetAccessTests(unittest.TestCase):
    def test_https_bearer_and_live_websocket_revocation(self):
        url = os.environ["MEDIA_SERVER_TEST_TAILNET_URL"].rstrip("/")
        self.assertTrue(url.startswith("https://"))
        port = int(os.getenv("MEDIA_SERVER_TEST_TAILNET_PORT", "8090"))
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "output"
            source.mkdir()
            media = root / "media"
            media.mkdir()
            settings = replace(main.settings, data_dir=root / "data", sqlite_path=root / "data" / "metadata.sqlite",
                thumbs_dir=root / "thumbs", auth_token=None, media_roots=[str(media)], startup_rescan=False,
                xviewer_saved_images_dir=root / "xsaved", comfy_output_dir=source,
                generated_library_dir=root / "generated", comfy_url=None, comfy_presets_path=None)
            store = DeviceTokens(settings.data_dir / "device_tokens.sqlite")
            identifier, token = store.issue("temporary-tailnet-probe")
            auth = {"Authorization": f"Bearer {token}"}
            session = requests.Session()
            session.trust_env = False
            with patch.object(main, "settings", settings), serve(main.app, port), session:
                self.assertEqual(session.get(url + "/health", timeout=45).status_code, 401)
                self.assertEqual(session.get(url + "/health", headers=auth, timeout=15).status_code, 200)
                self.assertEqual(session.get(url + "/generated/events", headers=auth, timeout=15).status_code, 200)
                self.assertEqual(session.post(url + "/generated/search", headers={**auth, "Origin": "https://untrusted.example"},
                    json={}, timeout=15).status_code, 403)

                async def revoke():
                    async with connect(url.replace("https://", "wss://", 1) + "/generated/events/ws",
                                       extra_headers=auth, open_timeout=15) as socket:
                        store.revoke(identifier)
                        with self.assertRaises(ConnectionClosed):
                            await asyncio.wait_for(socket.recv(), 6)
                asyncio.run(revoke())
                self.assertEqual(session.get(url + "/health", headers=auth, timeout=15).status_code, 401)
