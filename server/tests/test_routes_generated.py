import asyncio
from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import secrets
import socket
from tempfile import TemporaryDirectory
import threading
import time
from types import SimpleNamespace
import unittest

from fastapi import FastAPI
from PIL import Image
import requests
import uvicorn
from websockets.legacy.client import connect
from websockets.exceptions import InvalidHandshake

from server.api.routes_generated import router
from server.services.generated_library import GeneratedLibrary


@contextmanager
def serve(app, port=0):
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", port))
        port = sock.getsockname()[1]
        server = uvicorn.Server(uvicorn.Config(app, log_level="error", proxy_headers=False))
        worker = threading.Thread(target=server.run, kwargs={"sockets": [sock]}, daemon=True)
        worker.start()
        try:
            deadline = time.monotonic() + 10
            while not server.started:
                if not worker.is_alive() or time.monotonic() > deadline:
                    raise RuntimeError("Loopback test server did not start")
                time.sleep(0.02)
            yield port
        finally:
            server.should_exit = True
            worker.join(10)


class GeneratedRoutesTests(unittest.TestCase):
    def test_authenticated_import_replay_download_and_disabled_mode(self):
        with TemporaryDirectory() as temp:
            source = Path(temp) / "output"
            source.mkdir()
            library = GeneratedLibrary(source, Path(temp) / "library")
            app = FastAPI()
            app.include_router(router)
            token = secrets.token_hex(16)
            app.state.settings = SimpleNamespace(auth_token=token)
            app.state.generated_library = library
            auth = {"Authorization": f"Bearer {token}"}
            library.start()
            try:
                with serve(app) as port:
                    url = f"http://127.0.0.1:{port}/generated"
                    ws_url = f"ws://127.0.0.1:{port}/generated/events/ws"
                    self.assertEqual(requests.get(url + "/events", timeout=3).status_code, 401)
                    self.assertEqual(requests.get(url + "/events", headers={"Authorization": "Bearer bad"},
                                                  timeout=3).status_code, 401)

                    path = source / "output.png"
                    temporary = source / "output.tmp"
                    Image.new("RGB", (6, 8), "green").save(temporary, format="PNG")
                    temporary.replace(path)
                    payload = path.read_bytes()
                    digest = hashlib.sha256(payload).hexdigest()

                    async def notification():
                        with self.assertRaises(InvalidHandshake):
                            async with connect(ws_url):
                                self.fail("Unauthenticated socket accepted")
                        async with connect(ws_url, extra_headers=auth) as ws:
                            return json.loads(await asyncio.wait_for(ws.recv(), 25))

                    expected = {"items": [{"seq": 1, "mediaId": digest}]}
                    self.assertEqual(asyncio.run(notification()), expected)
                    def get(route):
                        return requests.get(url + route, headers=auth, timeout=3)
                    self.assertEqual(get("/events").json(), expected)
                    self.assertEqual(get("/events?after=1").json(), {"items": []})
                    self.assertEqual(get("/media/" + digest).content, payload)
                    self.assertEqual(get("/media/" + digest + "/thumbnail").headers["Content-Type"], "image/png")
                    self.assertEqual(get("/media/..%5Cgenerated.sqlite").status_code, 404)
                    self.assertEqual(get("/media/" + "a" * 64).status_code, 404)
                    app.state.settings.auth_token = None
                    self.assertEqual(get("/events").status_code, 503)
            finally:
                library.close()
