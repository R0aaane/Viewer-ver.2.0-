"""Persistent host-side ComfyUI jobs. Submission is never blindly retried."""
import asyncio
import hashlib
import json
import logging
import os
import sqlite3
import threading
import time
import uuid
from contextlib import closing
from urllib.parse import urlsplit

import requests
from websockets.legacy.client import connect

from server.services.generation_presets import GenerationPresets

logger = logging.getLogger(__name__)
TERMINAL = ("completed", "failed", "cancelled")


class JobConflict(ValueError):
    pass


class GenerationJobs:
    def __init__(self, library, url, presets_path, timeout_seconds=21600):
        parsed = urlsplit(url)
        if (parsed.scheme != "http" or parsed.hostname not in ("127.0.0.1", "localhost", "::1")
                or parsed.username or parsed.password or parsed.path not in ("", "/")
                or parsed.query or parsed.fragment):
            raise ValueError("ComfyUI must use a localhost HTTP URL")
        self.url = url.rstrip("/")
        if not 60 <= timeout_seconds <= 604800:
            raise ValueError("Generation timeout must be between 60 seconds and 7 days")
        self.timeout_seconds = timeout_seconds
        self.library = library
        self.presets = GenerationPresets(presets_path)
        self.stop = threading.Event()
        self.wake = threading.Event()
        self.client_id = str(uuid.uuid4())
        self.thread = threading.Thread(target=self._run, name="comfy-jobs", daemon=True)
        self.http = requests.Session()
        self.http.trust_env = False
        with closing(library.connect()) as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS generation_jobs (
                    id TEXT PRIMARY KEY, request_key TEXT NOT NULL UNIQUE,
                    request_hash TEXT NOT NULL, preset TEXT NOT NULL, workflow TEXT NOT NULL,
                    state TEXT NOT NULL, prompt_id TEXT, created REAL NOT NULL,
                    updated REAL NOT NULL, submitted REAL, error TEXT,
                    progress TEXT, results TEXT NOT NULL DEFAULT '[]'
                );
            """)

    def start(self):
        self.thread.start()

    def close(self):
        self.stop.set()
        self.wake.set()
        self.thread.join()
        self.http.close()

    def create(self, key, preset, parameters):
        payload = json.dumps([preset, parameters], sort_keys=True, allow_nan=False)
        digest = hashlib.sha256(payload.encode()).hexdigest()
        with closing(self.library.connect()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            existing = db.execute("SELECT * FROM generation_jobs WHERE request_key=?", (key,)).fetchone()
            if existing:
                if existing["request_hash"] != digest:
                    raise JobConflict("Idempotency-Key was already used with different settings")
                return self._public(existing)
            graph = self.presets.build(preset, parameters)
            identifier = str(uuid.uuid4())
            now = time.time()
            db.execute("""INSERT INTO generation_jobs
                (id,request_key,request_hash,preset,workflow,state,created,updated)
                VALUES (?,?,?,?,?,'queued',?,?)""",
                (identifier, key, digest, preset, json.dumps(graph, allow_nan=False), now, now))
        self.wake.set()
        return self.get(identifier)

    @staticmethod
    def _public(row):
        return {key: row[key] for key in ("id", "preset", "state", "created", "updated", "error")} | {
            "progress": json.loads(row["progress"]) if row["progress"] else None,
            "mediaIds": json.loads(row["results"])}

    def get(self, identifier):
        with closing(self.library.connect()) as db:
            row = db.execute("SELECT * FROM generation_jobs WHERE id=?", (identifier,)).fetchone()
        return self._public(row) if row else None

    def list(self, before=None):
        with closing(self.library.connect()) as db:
            rows = db.execute("""SELECT * FROM generation_jobs WHERE created < ?
                ORDER BY created DESC LIMIT 100""", (before or time.time() + 1,)).fetchall()
        return [self._public(row) for row in rows]

    def cancel(self, identifier):
        with closing(self.library.connect()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT state FROM generation_jobs WHERE id=?", (identifier,)).fetchone()
            if not row:
                return None
            if row["state"] == "importing":
                raise JobConflict("Images are already being imported")
            if row["state"] not in TERMINAL:
                state = "cancelled" if row["state"] == "queued" else "cancel_requested"
                db.execute("UPDATE generation_jobs SET state=?,updated=? WHERE id=?",
                           (state, time.time(), identifier))
        self.wake.set()
        return self.get(identifier)

    def _update(self, identifier, **values):
        values["updated"] = time.time()
        with closing(self.library.connect()) as db, db:
            # Cancellation wins against concurrently received progress/completion.
            state = values.get("state")
            if state and state not in ("cancelled", "failed"):
                condition = " AND state <> 'cancel_requested'"
            else:
                condition = ""
            changed = db.execute("UPDATE generation_jobs SET " + ",".join(f"{k}=?" for k in values)
                                 + " WHERE id=?" + condition, (*values.values(), identifier)).rowcount
        if changed and state in TERMINAL:
            self.wake.set()
        return changed

    def _get_json(self, path):
        response = self.http.get(self.url + path, timeout=(3, 10))
        response.raise_for_status()
        return response.json()

    def _post(self, path, data):
        response = self.http.post(self.url + path, json=data, timeout=(3, 10))
        response.raise_for_status()
        return response

    def _run(self):
        # One worker across FastAPI processes; the OS releases the lock on crash.
        while not self.stop.is_set():
            with closing(sqlite3.connect(self.library.root / "generation_worker.sqlite", timeout=1)) as lock:
                try:
                    lock.execute("BEGIN IMMEDIATE")
                except sqlite3.OperationalError:
                    self.stop.wait(2)
                    continue
                socket_thread = threading.Thread(target=lambda: asyncio.run(self._watch()), daemon=True)
                socket_thread.start()
                try:
                    while not self.stop.is_set():
                        try:
                            self.tick()
                        except Exception:
                            logger.exception("Generation worker will retry reconciliation")
                        self.wake.wait(3)
                        self.wake.clear()
                finally:
                    socket_thread.join()

    async def _watch(self):
        while not self.stop.is_set():
            try:
                async with connect(self.url.replace("http://", "ws://", 1) + "/ws?clientId=" + self.client_id,
                                   open_timeout=3, close_timeout=1, max_size=2 * 1024 * 1024) as socket:
                    while not self.stop.is_set():
                        try:
                            raw = await asyncio.wait_for(socket.recv(), 1)
                        except asyncio.TimeoutError:
                            continue
                        if isinstance(raw, bytes):
                            continue
                        message = json.loads(raw)
                        data = message.get("data", {})
                        prompt_id = data.get("prompt_id")
                        if prompt_id:
                            with closing(self.library.connect()) as db, db:
                                progress = None
                                if message.get("type") == "progress":
                                    progress = json.dumps({"value": data.get("value"), "max": data.get("max")})
                                db.execute("""UPDATE generation_jobs SET progress=COALESCE(?,progress)
                                    WHERE prompt_id=? AND state='running'""", (progress, prompt_id))
                        self.wake.set()
            except Exception:
                # HTTP history remains authoritative when sockets disconnect.
                for _ in range(3):
                    if self.stop.is_set():
                        return
                    await asyncio.sleep(1)

    def tick(self):
        with closing(self.library.connect()) as db:
            job = db.execute("""SELECT * FROM generation_jobs
                WHERE state NOT IN ('completed','failed','cancelled') ORDER BY created LIMIT 1""").fetchone()
        if job is None:
            return
        identifier = job["id"]
        try:
            if job["state"] == "queued" and time.time() - job["created"] > self.timeout_seconds:
                self._update(identifier, state="failed", error="生成待機がタイムアウトしました。接続状態を確認してください")
                return
            if job["state"] == "queued":
                # Check availability before crossing the durable submission boundary.
                self._get_json("/queue")
                with closing(self.library.connect()) as db, db:
                    changed = db.execute("""UPDATE generation_jobs SET state='submitting',submitted=?,updated=?
                        WHERE id=? AND state='queued'""", (time.time(), time.time(), identifier)).rowcount
                if not changed:
                    return
                response = self._post("/prompt", {"prompt": json.loads(job["workflow"]),
                    "prompt_id": identifier, "client_id": self.client_id,
                    "extra_data": {"pdf_viewer_job": identifier}}).json()
                prompt_id = response.get("prompt_id")
                if not isinstance(prompt_id, str) or not prompt_id:
                    raise ValueError("ComfyUI did not return a prompt ID")
                # Preserve the ID even if a cancellation arrived during submission.
                self._update(identifier, prompt_id=prompt_id, error=None)
                self._update(identifier, state="running")
                return
            self._reconcile(job)
        except requests.HTTPError as exc:
            if exc.response is not None and 400 <= exc.response.status_code < 500:
                self._update(identifier, state="failed", error=f"ComfyUI HTTP {exc.response.status_code}")
            else:
                self._update(identifier, error="ComfyUIとの通信を再試行しています")
        except (requests.RequestException, OSError) as exc:
            if isinstance(exc, OSError) and getattr(exc, "errno", None) == 28:
                self._update(identifier, error="ストレージ容量不足です。空き容量の確保後に再試行します")
            elif job["state"] != "importing" and job["submitted"] and time.time() - job["submitted"] > self.timeout_seconds:
                self._update(identifier, state="failed", error="生成がタイムアウトしました。ComfyUIの状態を確認してください")
            else:
                self._update(identifier, error="ComfyUIとの通信を再試行しています")
        except (ValueError, KeyError, TypeError) as exc:
            self._update(identifier, state="failed", error=str(exc)[:300])

    @staticmethod
    def _owns(entry, identifier):
        return len(entry) > 3 and isinstance(entry[3], dict) and entry[3].get("pdf_viewer_job") == identifier

    def _reconcile(self, job):
        identifier = job["id"]
        prompt_id = job["prompt_id"]
        queue = self._get_json("/queue")
        entries = queue.get("queue_running", []) + queue.get("queue_pending", [])
        if not prompt_id:
            for entry in entries:
                if self._owns(entry, identifier):
                    prompt_id = entry[1]
                    break
            history = self._get_json("/history?max_items=1000")
            if not prompt_id:
                for candidate, value in history.items():
                    if self._owns(value.get("prompt", []), identifier):
                        prompt_id = candidate
                        break
            if prompt_id:
                self._update(identifier, prompt_id=prompt_id)
        else:
            history = self._get_json("/history/" + requests.utils.quote(prompt_id, safe=""))
        result = history.get(prompt_id)
        cancelled = self.get(identifier)["state"] == "cancel_requested"
        if cancelled:
            if result:
                self._update(identifier, state="cancelled", error=None)
                return
            if time.time() - job["submitted"] > self.timeout_seconds:
                self._update(identifier, state="cancelled", error="待機時間を超えたためキャンセルを確定しました。ComfyUIを確認してください")
                return
            pending = any(entry[1] == prompt_id for entry in queue.get("queue_pending", []))
            running = any(entry[1] == prompt_id for entry in queue.get("queue_running", []))
            if pending:
                self._post("/queue", {"delete": [prompt_id]})
                return
            if running:
                # Older ComfyUI versions ignore prompt_id on /interrupt. Never call it.
                self._update(identifier, error="実行終了を待ってキャンセルします")
                return
            if time.time() - job["submitted"] > 60:
                self._update(identifier, state="cancelled", error=None)
            return
        if result:
            status = result.get("status", {})
            if status.get("status_str") == "error":
                self._update(identifier, state="failed", error="ComfyUIで生成が失敗しました")
                return
            if not status.get("completed"):
                return
            if self._update(identifier, state="importing", error=None):
                self._import(job, result)
        elif time.time() - job["submitted"] > self.timeout_seconds:
            self._update(identifier, state="failed", error="生成がタイムアウトしました。ComfyUIの状態を確認してください")
        elif prompt_id and any(entry[1] == prompt_id for entry in entries):
            self._update(identifier, state="running", error=None)
        elif time.time() - job["submitted"] > 60:
            self._update(identifier, state="failed", error="送信結果または実行履歴を確認できません。ComfyUIを確認してください")

    def _import(self, job, result):
        images = [image for output in result.get("outputs", {}).values()
                  for image in output.get("images", []) if image.get("type") == "output"]
        if not images:
            raise ValueError("ワークフローに保存画像がありません。SaveImageを確認してください")
        media_ids = json.loads(job["results"])
        scratch = self.library.root / "generation-download.part"
        try:
            for index, image in enumerate(images):
                if index < len(media_ids):
                    continue
                if self.stop.is_set():
                    return
                with self.http.get(self.url + "/view", params={key: image.get(key, "")
                                   for key in ("filename", "subfolder", "type")}, stream=True,
                                   timeout=(3, 10)) as response:
                    response.raise_for_status()
                    size = 0
                    with scratch.open("wb") as out:
                        for chunk in response.iter_content(1024 * 1024):
                            size += len(chunk)
                            if size > 256 * 1024 * 1024:
                                raise ValueError("生成画像が256 MiBを超えています")
                            if self.stop.is_set():
                                return
                            out.write(chunk)
                        out.flush()
                        os.fsync(out.fileno())
                digest = self.library.import_download(scratch)
                if digest is None:
                    return
                media_ids.append(digest)
                self._update(job["id"], results=json.dumps(media_ids))
            self._update(job["id"], state="completed", error=None)
        finally:
            scratch.unlink(missing_ok=True)
