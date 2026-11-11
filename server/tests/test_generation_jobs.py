import hashlib
import io
import json
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import time
import unittest
from unittest.mock import patch

from fastapi import FastAPI, Request, WebSocket
from fastapi.responses import Response
from PIL import Image
import requests

from server.api.routes_generation_jobs import router
from server.services.generated_library import GeneratedLibrary
from server.services.generation_jobs import GenerationJobs, JobConflict
from server.tests.test_routes_generated import serve


class GenerationTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        source = root / "output"
        source.mkdir()
        self.library = GeneratedLibrary(source, root / "library")
        self.path = root / "presets.json"
        self.path.write_text(json.dumps([{"id": "fixture", "workflow": {
            "1": {"class_type": "CLIPTextEncode", "inputs": {"text": "", "clip": ["2", 1]}},
            "2": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "allowed.safetensors"}},
            "3": {"class_type": "KSampler", "inputs": {"steps": 20}},
        }, "parameters": {
            "positive": {"node": "1", "input": "text", "type": "text", "default": "", "maxLength": 100},
            "checkpoint": {"node": "2", "input": "ckpt_name", "type": "choice",
                           "default": "allowed.safetensors", "choices": ["allowed.safetensors"]},
            "steps": {"node": "3", "input": "steps", "type": "integer", "default": 20, "min": 1, "max": 40},
        }}]), encoding="utf-8")
        self.pending = []
        self.running = []
        self.history = {}
        self.submissions = []
        self.deletions = []
        self.sockets = 0
        image = io.BytesIO()
        Image.new("RGB", (8, 8), "green").save(image, format="PNG")
        self.image = image.getvalue()
        self.comfy = FastAPI()

        @self.comfy.get("/queue")
        def queue():
            return {"queue_pending": self.pending, "queue_running": self.running}

        @self.comfy.post("/prompt")
        async def prompt(request: Request):
            body = await request.json()
            self.submissions.append(body)
            # An older ComfyUI version can assign its own prompt ID.
            identifier = "legacy-" + body["prompt_id"]
            self.pending.append([0, identifier, body["prompt"], body["extra_data"], []])
            return {"prompt_id": identifier}

        @self.comfy.get("/history")
        def history():
            return self.history

        @self.comfy.get("/history/{identifier}")
        def one_history(identifier: str):
            return {identifier: self.history[identifier]} if identifier in self.history else {}

        @self.comfy.post("/queue")
        async def delete(request: Request):
            body = await request.json()
            self.deletions.append(body)
            self.pending[:] = [item for item in self.pending if item[1] not in body["delete"]]
            return {}

        @self.comfy.get("/view")
        def view():
            return Response(self.image, media_type="image/png")

        @self.comfy.websocket("/ws")
        async def websocket(socket: WebSocket):
            await socket.accept()
            self.sockets += 1
            try:
                while True:
                    await socket.receive_text()
            except Exception:
                pass

    def manager(self, port=8188):
        jobs = GenerationJobs(self.library, f"http://127.0.0.1:{port}", self.path)
        self.addCleanup(jobs.http.close)
        return jobs

    def finish(self, entry, error=False):
        self.pending.clear()
        self.running.clear()
        self.history[entry[1]] = {"prompt": entry, "status": {"completed": True,
            "status_str": "error" if error else "success"},
            "outputs": {"9": {"images": [{"filename": "output.png", "subfolder": "", "type": "output"}]}}}

    def test_presets_validation_and_concurrent_idempotency(self):
        jobs = self.manager()
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: jobs.create("same-key", "fixture", {"positive": "test"}), range(8)))
        self.assertEqual(len({j["id"] for j in results}), 1)
        with self.assertRaises(JobConflict):
            jobs.create("same-key", "fixture", {"positive": "different"})
        for values in ({"workflow": {}}, {"steps": 0}, {"steps": True}, {"steps": 2.5},
                       {"checkpoint": "unapproved.safetensors"}, {"positive": "a" * 101}):
            with self.assertRaises(ValueError):
                jobs.create("bad-key", "fixture", values)
        restarted = self.manager()
        self.assertEqual(restarted.create("same-key", "fixture", {"positive": "test"})["id"], results[0]["id"])
        cancelled = restarted.cancel(results[0]["id"])
        self.assertEqual(cancelled["state"], "cancelled")
        self.assertNotIn("workflow", jobs.presets.public()[0])

    def test_lost_submit_response_recovered_without_resubmit_then_import(self):
        with serve(self.comfy) as port:
            jobs = self.manager(port)
            job = jobs.create("lost-response", "fixture", {})
            original_post = jobs.http.post

            def lost(*args, **kwargs):
                original_post(*args, **kwargs)
                raise requests.ConnectionError("response lost")

            with patch.object(jobs.http, "post", side_effect=lost):
                jobs.tick()
            self.assertEqual(jobs.get(job["id"])["state"], "submitting")
            restarted = self.manager(port)
            restarted.tick()
            self.assertEqual(restarted.get(job["id"])["state"], "running")
            self.finish(self.pending[0])
            restarted.tick()
            result = restarted.get(job["id"])
            self.assertEqual(result["state"], "completed")
            digest = hashlib.sha256(self.image).hexdigest()
            self.assertEqual(result["mediaIds"], [digest])
            self.assertEqual(self.library.media_path(digest, False).read_bytes(), self.image)
            self.assertEqual(len(self.submissions), 1)

    def test_cancel_running_waits_and_pending_deletes_only_own_id(self):
        with serve(self.comfy) as port:
            jobs = self.manager(port)
            job = jobs.create("pending", "fixture", {})
            jobs.tick()
            own = self.pending[0]
            foreign = [0, "foreign", {}, {}, []]
            self.pending.append(foreign)
            jobs.cancel(job["id"])
            jobs.tick()
            self.assertEqual(self.deletions, [{"delete": [own[1]]}])
            self.assertEqual(self.pending, [foreign])
            with closing(self.library.connect()) as db, db:
                db.execute("UPDATE generation_jobs SET submitted=0 WHERE id=?", (job["id"],))
            jobs.tick()
            self.assertEqual(jobs.get(job["id"])["state"], "cancelled")
            job = jobs.create("running", "fixture", {})
            jobs.tick()
            own = self.pending.pop()
            self.running = [own, foreign]
            jobs.cancel(job["id"])
            jobs.tick()
            self.assertEqual(jobs.get(job["id"])["state"], "cancel_requested")
            self.assertEqual(self.running, [own, foreign])
            self.finish(own)
            jobs.tick()
            self.assertEqual(jobs.get(job["id"])["state"], "cancelled")
            self.assertEqual(jobs.get(job["id"])["mediaIds"], [])

    def test_http_auth_restoration_and_host_worker(self):
        with serve(self.comfy) as port:
            jobs = self.manager(port)
            app = FastAPI()
            app.state.settings = SimpleNamespace(auth_token="test-token")
            app.state.generation_jobs = jobs
            app.include_router(router)
            auth = {"Authorization": "Bearer test-token", "Idempotency-Key": "fixture-request-123"}
            replica = self.manager(port)
            jobs.start()
            replica.start()
            try:
                with serve(app) as api_port:
                    url = f"http://127.0.0.1:{api_port}/generated"
                    self.assertEqual(requests.get(url + "/jobs", timeout=3).status_code, 401)
                    self.assertEqual(requests.get(url + "/presets", headers=auth, timeout=3).status_code, 200)
                    body = {"preset": "fixture", "parameters": {}}
                    first = requests.post(url + "/jobs", headers=auth, json=body, timeout=3)
                    self.assertEqual(first.status_code, 200)
                    second = requests.post(url + "/jobs", headers=auth, json=body, timeout=3)
                    self.assertEqual(first.json()["id"], second.json()["id"])
                    conflict = requests.post(url + "/jobs", headers=auth,
                        json={"preset": "fixture", "parameters": {"steps": 21}}, timeout=3)
                    self.assertEqual(conflict.status_code, 409)
                # Client API has gone away; the host worker continues.
                end = time.monotonic() + 10
                while not self.pending and time.monotonic() < end:
                    time.sleep(.02)
                self.assertTrue(self.pending)
                self.finish(self.pending[0])
                while jobs.get(first.json()["id"])["state"] != "completed" and time.monotonic() < end:
                    time.sleep(.05)
                self.assertEqual(jobs.get(first.json()["id"])["state"], "completed")
                self.assertGreater(self.sockets, 0)
                self.assertEqual(len(self.submissions), 1)
            finally:
                replica.close()
                jobs.close()

    def test_import_retry_and_failure_states(self):
        with serve(self.comfy) as port:
            jobs = self.manager(port)
            job = jobs.create("retry-import", "fixture", {})
            jobs.tick()
            self.finish(self.pending[0])
            with patch.object(self.library, "import_download", return_value=None):
                jobs.tick()
            self.assertEqual(jobs.get(job["id"])["state"], "importing")
            with self.assertRaises(JobConflict):
                jobs.cancel(job["id"])
            restarted = self.manager(port)
            restarted.tick()
            self.assertEqual(restarted.get(job["id"])["state"], "completed")
            job = jobs.create("failure", "fixture", {})
            jobs.tick()
            self.finish(self.pending[0], error=True)
            jobs.tick()
            self.assertEqual(jobs.get(job["id"])["state"], "failed")

    def test_offline_queue_missing_history_and_invalid_image(self):
        with serve(self.comfy) as port:
            jobs = self.manager(port)
            job = jobs.create("offline", "fixture", {})
            with patch.object(jobs.http, "get", side_effect=requests.ConnectionError("offline")):
                jobs.tick()
            self.assertEqual(jobs.get(job["id"])["state"], "queued")
            self.assertEqual(self.submissions, [])
            jobs.tick()
            self.pending.clear()
            with closing(self.library.connect()) as db, db:
                db.execute("UPDATE generation_jobs SET submitted=0 WHERE id=?", (job["id"],))
            jobs.tick()
            self.assertEqual(jobs.get(job["id"])["state"], "failed")
            self.assertEqual(len(self.submissions), 1)
            job = jobs.create("invalid-image", "fixture", {})
            jobs.tick()
            self.finish(self.pending[0])
            self.image = b"invalid PNG"
            jobs.tick()
            self.assertEqual(jobs.get(job["id"])["state"], "failed")
            self.assertEqual(jobs.get(job["id"])["mediaIds"], [])

    def test_example_presets_are_valid_and_editable(self):
        from server.services.generation_presets import GenerationPresets
        presets = GenerationPresets(Path(__file__).parents[1] / "config" / "comfy_presets.example.json")
        graph = presets.build("txt2img", {"positive": "test", "seed": 9007199254740991, "width": 1024})
        self.assertEqual(graph["6"]["inputs"]["text"], "test")
        self.assertEqual(graph["5"]["inputs"]["width"], 1024)
        graph = presets.build("txt2img-lora", {"lora_model_strength": -1})
        self.assertEqual(graph["10"]["inputs"]["strength_model"], -1)
        with self.assertRaises(ValueError):
            presets.build("txt2img", {"width": 513})

    def test_timeout_does_not_resubmit_or_interrupt_other_prompts(self):
        with serve(self.comfy) as port:
            jobs = self.manager(port)
            jobs.timeout_seconds = 60
            job = jobs.create("timeout", "fixture", {})
            jobs.tick()
            with closing(self.library.connect()) as db, db:
                db.execute("UPDATE generation_jobs SET submitted=? WHERE id=?", (time.time() - 61, job["id"]))
            jobs.tick()
            self.assertEqual(jobs.get(job["id"])["state"], "failed")
            self.assertEqual(len(self.submissions), 1)
            self.assertEqual(len(self.pending), 1)
            self.assertEqual(self.deletions, [])

    def test_disk_full_during_import_recovers_without_submitting_again(self):
        with serve(self.comfy) as port:
            jobs = self.manager(port)
            job = jobs.create("disk-full", "fixture", {})
            jobs.tick()
            self.finish(self.pending[0])
            with patch.object(self.library, "import_download", side_effect=OSError(28, "disk full")):
                jobs.tick()
            self.assertEqual(jobs.get(job["id"])["state"], "importing")
            self.assertIn("容量不足", jobs.get(job["id"])["error"])
            jobs.tick()
            self.assertEqual(jobs.get(job["id"])["state"], "completed")
            self.assertEqual(len(self.submissions), 1)
