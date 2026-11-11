"""Reproducible 30k-image benchmark. Uses only its marked, isolated fixture tree."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing, contextmanager
import ctypes
from ctypes import wintypes
import hashlib
import io
import json
import math
import os
from pathlib import Path
import platform
import random
import secrets
import shutil
import signal
import socket
import sqlite3
import statistics
import struct
import subprocess
import sys
import threading
import time
import zlib

from PIL import Image
import requests
import uvicorn
from fastapi import FastAPI, Request, WebSocket
from fastapi.responses import Response

from server.services.generated_library import GeneratedLibrary

MARKER = "pdf-viewer-performance-fixture-v1"
HTTP_COUNTERS = {"thumbnail_requests": 0, "thumbnail_bytes": 0, "search_requests": 0}


class BenchmarkCounters:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        thumbnail = scope.get("type") == "http" and scope.get("path", "").endswith("/thumbnail")
        if thumbnail:
            HTTP_COUNTERS["thumbnail_requests"] += 1
        if scope.get("path") == "/generated/search":
            HTTP_COUNTERS["search_requests"] += 1
        async def counted_send(message):
            if thumbnail and message["type"] == "http.response.body":
                HTTP_COUNTERS["thumbnail_bytes"] += len(message.get("body", b""))
            await send(message)
        await self.app(scope, receive, counted_send)


def benchmark_app():
    from server.main import app, settings
    from server.services.auth_service import require_bearer_token
    from starlette.responses import JSONResponse
    from starlette.routing import Route
    from server.services.generation_jobs import GenerationJobs
    if settings.generated_library_dir is None:
        raise ValueError("Use the marked benchmark fixture")
    check_root(settings.generated_library_dir.parent)
    app.add_middleware(BenchmarkCounters)
    async def counters(request):
        require_bearer_token(request, request.headers.get("authorization"))
        return JSONResponse(dict(HTTP_COUNTERS, pid=os.getpid(), memory=memory()))
    async def job_mode(request):
        import importlib.util
        require_bearer_token(request, request.headers.get("authorization"))
        jobs = request.app.state.generation_jobs
        if any(row["state"] not in ("completed", "failed", "cancelled") for row in jobs.list()):
            return JSONResponse({"detail": "Drain the benchmark queue before switching"}, status_code=409)
        mode = request.query_params.get("mode")
        if mode == "baseline":
            root = request.app.state.settings.generated_library_dir.parent
            reference = json.loads((root / "baseline-prefix.json").read_text(encoding="utf-8"))
            path = root / "baseline_jobs.py"
            if hashlib.sha256(path.read_bytes()).hexdigest() != reference["source_sha256"]["server/services/generation_jobs.py"]:
                raise ValueError("Baseline job source hash mismatch")
            spec = importlib.util.spec_from_file_location("benchmark_baseline_jobs", path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            method = module.GenerationJobs._update
        elif mode == "improved":
            method = GenerationJobs._update
        else:
            return JSONResponse({"detail": "Unknown benchmark mode"}, status_code=422)
        jobs._update = method.__get__(jobs, type(jobs))
        return JSONResponse({"mode": mode})
    app.router.routes.insert(0, Route("/performance/counters", counters))
    app.router.routes.insert(0, Route("/performance/job-mode", job_mode, methods=["POST"]))
    return app


def emit(**values):
    print(json.dumps(values, ensure_ascii=True), flush=True)


def save(path, values):
    temporary = path.with_suffix(path.suffix + ".part")
    temporary.write_text(json.dumps(values, indent=2), encoding="utf-8")
    temporary.replace(path)


def memory(pid=None):
    class Counters(ctypes.Structure):
        _fields_ = [("cb", wintypes.DWORD), ("faults", wintypes.DWORD)] + [
            (name, ctypes.c_size_t) for name in ("peak_ws", "ws", "peak_paged", "paged", "peak_nonpaged",
                                                "nonpaged", "pagefile", "peak_pagefile", "private")]
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    handle = kernel.OpenProcess(0x410, False, pid or os.getpid())
    if not handle:
        raise ctypes.WinError(ctypes.get_last_error())
    counter = Counters()
    counter.cb = ctypes.sizeof(counter)
    function = ctypes.WinDLL("psapi", use_last_error=True).GetProcessMemoryInfo
    function.argtypes = [wintypes.HANDLE, ctypes.POINTER(Counters), wintypes.DWORD]
    try:
        if not function(handle, ctypes.byref(counter), counter.cb):
            raise ctypes.WinError(ctypes.get_last_error())
        return {"working_set_mib": counter.ws / 2**20, "peak_working_set_mib": counter.peak_ws / 2**20,
                "private_mib": counter.private / 2**20}
    finally:
        kernel.CloseHandle(handle)


class MemorySampler:
    def __init__(self, pid=None):
        self.pid = pid
        self.stop = threading.Event()
        self.peak = {"working_set_mib": 0, "peak_working_set_mib": 0, "private_mib": 0}
        self.thread = threading.Thread(target=self.run, daemon=True)

    def run(self):
        while not self.stop.wait(.1):
            try:
                for key, value in memory(self.pid).items():
                    self.peak[key] = max(self.peak[key], value)
            except OSError:
                return

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *args):
        self.stop.set()
        self.thread.join()


def distribution(values):
    ordered = sorted(values)
    return {"n": len(ordered), "p50_ms": statistics.median(ordered),
            "p95_ms": ordered[min(len(ordered)-1, math.ceil(len(ordered) * .95)-1)],
            "max_ms": ordered[-1], "mean_ms": statistics.mean(ordered)}


def check_root(root):
    root = root.resolve()
    if not (root / "fixture.json").is_file():
        raise ValueError("Missing benchmark ownership marker")
    fixture = json.loads((root / "fixture.json").read_text(encoding="utf-8"))
    if fixture["owner"] != MARKER:
        raise ValueError("This directory belongs to another task")
    return fixture


def png_chunk(kind, payload):
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xffffffff)


def image_bytes(base, index):
    prompt = {"3": {"class_type": "KSampler", "inputs": {"seed": index, "steps": 25, "cfg": 7,
        "sampler_name": "euler", "scheduler": "normal", "positive": ["6", 0], "negative": ["7", 0],
        "model": ["4", 0], "latent_image": ["5", 0]}},
        "4": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "benchmark-fixture.safetensors"}},
        "5": {"class_type": "EmptyLatentImage", "inputs": {"width": 512, "height": 768, "batch_size": 1}},
        "6": {"class_type": "CLIPTextEncode", "inputs": {"text": f"forest landscape seed-{index:06d} group-{index % 100:03d}"}},
        "7": {"class_type": "CLIPTextEncode", "inputs": {"text": "blur noise"}}}
    payload = png_chunk(b"tEXt", b"prompt\0" + json.dumps(prompt, separators=(",", ":")).encode())
    payload += png_chunk(b"tEXt", b"workflow\0" + json.dumps({"nodes": [], "fixture": index}).encode())
    return base[:-12] + payload + base[-12:]


def prepare(root, count):
    root.mkdir(parents=True, exist_ok=True)
    if any(root.iterdir()) and not (root / "fixture.json").exists():
        raise ValueError("Choose an empty benchmark directory")
    fixture = {"owner": MARKER, "count": count, "templates": [], "created": time.time(),
               "platform": platform.platform(), "processor": os.getenv("PROCESSOR_IDENTIFIER"), "logical_cpus": os.cpu_count()}
    if (root / "fixture.json").exists():
        old = check_root(root)
        if old["count"] != count:
            raise ValueError("Fixture size differs")
        fixture = old
    else:
        save(root / "fixture.json", fixture)
    source = root / "source"
    source.mkdir(exist_ok=True)
    templates = root / "templates"
    templates.mkdir(exist_ok=True)
    sizes = [(512, 768), (768, 512), (768, 1024), (1024, 768)]
    for index, size in enumerate(sizes):
        path = templates / f"{index}.png"
        if not path.exists():
            noise = random.Random(420 + index).randbytes(size[0] * size[1])
            image = Image.frombytes("L", size, noise).quantize(colors=16)
            image.save(path, optimize=False, compress_level=3)
        fixture["templates"] = [{"width": w, "height": h} for w, h in sizes]
    bases = [path.read_bytes() for path in sorted(templates.glob("*.png"))]
    started = time.perf_counter()
    total = 0
    for index in range(count):
        folder = source / f"{index // 300:03d}"
        folder.mkdir(exist_ok=True)
        path = folder / f"fixture_{index:06d}.png"
        if not path.exists():
            path.write_bytes(image_bytes(bases[index % len(bases)], index))
        total += path.stat().st_size
        if (index + 1) % 1000 == 0:
            emit(stage="prepare", files=index + 1, elapsed_s=round(time.perf_counter() - started, 2))
    fixture["source_bytes"] = total
    fixture["prepare_seconds"] = time.perf_counter() - started
    save(root / "fixture.json", fixture)
    emit(stage="prepared", source_gib=round(total / 2**30, 3))


@contextmanager
def mock_comfy(root, port):
    app = FastAPI()
    sockets = {}
    pending = []
    histories = {}
    outputs = {}
    base = (root / "templates" / "0.png").read_bytes()
    @app.websocket("/ws")
    async def socket_route(socket: WebSocket):
        await socket.accept()
        client = socket.query_params.get("clientId")
        sockets[client] = socket
        try:
            while True:
                await socket.receive_text()
        except Exception:
            sockets.pop(client, None)
    @app.get("/queue")
    def queue():
        return {"queue_running": pending, "queue_pending": []}
    @app.post("/prompt")
    async def prompt(request: Request):
        import asyncio
        body = await request.json()
        identifier = body["prompt_id"]
        entry = [0, identifier, body["prompt"], body["extra_data"], []]
        pending.append(entry)
        async def finish():
            await asyncio.sleep(.2)
            pending.remove(entry)
            outputs[identifier + ".png"] = image_bytes(base, 1000000 + len(outputs))
            histories[identifier] = {"prompt": entry, "status": {"completed": True, "status_str": "success"},
                "outputs": {"9": {"images": [{"filename": identifier + ".png", "subfolder": "", "type": "output"}]}}}
            socket = sockets.get(body["client_id"])
            if socket:
                await socket.send_json({"type": "execution_success", "data": {"prompt_id": identifier}})
        asyncio.create_task(finish())
        return {"prompt_id": identifier}
    @app.get("/history/{identifier}")
    def history(identifier: str):
        return {identifier: histories[identifier]} if identifier in histories else {}
    @app.get("/view")
    def view(filename: str):
        return Response(outputs[filename], media_type="image/png")
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", port))
        server = uvicorn.Server(uvicorn.Config(app, log_level="error", proxy_headers=False))
        thread = threading.Thread(target=server.run, kwargs={"sockets": [sock]}, daemon=True)
        thread.start()
        end = time.monotonic() + 10
        while not server.started:
            if time.monotonic() > end:
                raise RuntimeError("Mock ComfyUI did not start")
            time.sleep(.02)
        try:
            yield
        finally:
            server.should_exit = True
            thread.join(10)


def measure(root, label, port, *, serve=True):
    fixture = check_root(root)
    library_root = root / ("library-" + label)
    if library_root.exists():
        raise ValueError("Choose a new measurement label")
    report = {"label": label, "fixture": fixture, "started": time.time(), "memory_before": memory()}
    report["source_sha256"] = {str(path).replace("\\", "/"): hashlib.sha256(path.read_bytes()).hexdigest()
                               for path in map(Path, ("server/services/generated_library.py",
                                   "server/services/generated_catalog.py", "server/services/generation_jobs.py"))}
    report["import_prefix_samples"] = []
    library = GeneratedLibrary(root / "source", library_root)
    published = 0
    original_publish = library._publish
    started = time.perf_counter()
    def publish(*args):
        nonlocal published
        result = original_publish(*args)
        published += 1
        if published % 500 == 0:
            seconds = round(time.perf_counter() - started, 2)
            report["import_prefix_samples"].append({"images": published, "seconds": seconds})
            emit(stage="import", label=label, ready=published, elapsed_s=seconds)
        return result
    library._publish = publish
    with MemorySampler() as sampler:
        started = time.perf_counter()
        library.scan()
        report["observe_seconds"] = time.perf_counter() - started
        emit(stage="observed", label=label, seconds=round(report["observe_seconds"], 3))
        time.sleep(2.1)
        started = time.perf_counter()
        library.scan()
        report["import_seconds"] = time.perf_counter() - started
        report["initial_seconds_including_settle"] = report["observe_seconds"] + 2.1 + report["import_seconds"]
        with closing(library.connect()) as db:
            report["initial_ready"] = db.execute("SELECT COUNT(*) FROM images WHERE state='ready'").fetchone()[0]
        if report["initial_ready"] != fixture["count"]:
            raise RuntimeError("The initial corpus was not fully imported")
        unchanged = []
        for _ in range(3):
            started = time.perf_counter()
            library.scan()
            unchanged.append(time.perf_counter() - started)
        report["unchanged_scan_seconds"] = unchanged
        delta = root / "source" / "delta"
        if delta.exists():
            raise ValueError("A previous delta directory was not archived")
        delta.mkdir()
        base = (root / "templates" / "0.png").read_bytes()
        for index in range(100):
            (delta / f"delta_{index:06d}.png").write_bytes(image_bytes(base, fixture["count"] + index))
        started = time.perf_counter()
        library.scan()
        time.sleep(2.1)
        library.scan()
        report["delta_100_seconds_including_settle"] = time.perf_counter() - started
        delta.rename(root / ("delta-" + label))
        report["scan_memory_peak"] = sampler.peak
    report["scan_memory_after"] = memory()
    with closing(library.connect()) as db, db:
        digests = [row[0] for row in db.execute("SELECT digest FROM images ORDER BY digest")]
        db.executemany("INSERT INTO manual_tags VALUES(?,'free',?)", [(d, f"group-{i % 100:03d}") for i, d in enumerate(digests)])
        db.executemany("INSERT INTO manual_tags VALUES(?,'character',?)", [(d, f"character-{i % 20:02d}") for i, d in enumerate(digests)])
        db.executemany("INSERT INTO generated_favorites VALUES(?)", [(d,) for i, d in enumerate(digests) if i % 10 == 0])
    report["library_bytes"] = {folder: sum(p.stat().st_size for p in (library_root / folder).glob("*") if p.is_file())
                               for folder in ("originals", "thumbs")}
    save(root / (label + ".json"), report)
    if serve:
        serve_and_measure(root, label, port, report)


def serve_and_measure(root, label, port, report):
    token = secrets.token_urlsafe(32)
    service = root / ("service-" + label)
    service.mkdir(exist_ok=True)
    presets = root / "presets.json"
    presets.write_text(json.dumps([{"id": "fixture", "parameters": {}, "workflow": {
        "1": {"class_type": "SaveImage", "inputs": {"filename_prefix": "benchmark"}}}}]), encoding="utf-8")
    env = dict(os.environ, MEDIA_SERVER_HOST="127.0.0.1", MEDIA_SERVER_PORT=str(port),
        MEDIA_SERVER_AUTH_TOKEN=token, MEDIA_SERVER_DATA_DIR=str(service), MEDIA_SERVER_DB_PATH=str(service / "metadata.sqlite"),
        MEDIA_SERVER_MEDIA_ROOTS="", MEDIA_SERVER_STARTUP_RESCAN="false", MEDIA_SERVER_LOG_LEVEL="ERROR",
        MEDIA_SERVER_GENERATED_LIBRARY_DIR=str(root / ("library-" + label)), MEDIA_SERVER_COMFY_OUTPUT_DIR=str(root / "source"),
        MEDIA_SERVER_XVIEWER_SAVED_IMAGES_DIR=str(root / ("xsaved-" + label)),
        MEDIA_SERVER_COMFY_URL=f"http://127.0.0.1:{port+1}", MEDIA_SERVER_COMFY_PRESETS_PATH=str(presets))
    base_url = f"http://127.0.0.1:{port}"
    log = (root / (label + ".server.log")).open("w", encoding="utf-8")
    with mock_comfy(root, port + 1):
        process = subprocess.Popen([sys.executable, "-m", "uvicorn", "tool.benchmark_generated_library:benchmark_app", "--factory", "--host", "127.0.0.1",
            "--port", str(port), "--no-proxy-headers", "--log-level", "error"], env=env, stdout=log, stderr=subprocess.STDOUT)
        session = requests.Session()
        session.trust_env = False
        session.headers["Authorization"] = "Bearer " + token
        worker_pid = None
        try:
            deadline = time.monotonic() + 30
            while True:
                try:
                    if session.get(base_url + "/health", timeout=2).status_code == 200:
                        break
                except requests.RequestException:
                    pass
                if process.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("Benchmark backend startup failed; inspect the benchmark server log")
                time.sleep(.1)
            runtime = session.get(base_url + "/performance/counters", timeout=5)
            runtime.raise_for_status()
            # Windows venv's launcher PID is not the Python worker PID.
            worker_pid = runtime.json()["pid"]
            report["server_pid"] = worker_pid
            report["http_memory_start"] = memory(worker_pid)
            control = {"baseUrl": base_url, "token": token, "reportPath": str(root / (label + ".flutter.json")),
                       "stopPath": str(root / (label + ".stop"))}
            save(root / "control.json", control)
            cases = {
                "first": {}, "middle": {"offset": 14976}, "last": {"offset": 29952},
                "name": {"sort": "name"}, "oldest": {"sort": "oldest"},
                "prompt_common": {"prompt": "forest"}, "prompt_rare": {"prompt": "seed-029999"},
                "favorite": {"favorite": True}, "tag_and": {"all_tags": [{"category": "free", "name": "group-000"}]},
                "tag_not": {"no_tags": [{"category": "character", "name": "character-00"}]}}
            with MemorySampler(worker_pid) as sampler:
                searches = {}
                for name, query in cases.items():
                    samples = []
                    for index in range(35):
                        start = time.perf_counter()
                        response = session.post(base_url + "/generated/search", json=query, timeout=30)
                        response.raise_for_status()
                        response.json()
                        if index >= 5:
                            samples.append((time.perf_counter() - start) * 1000)
                    searches[name] = distribution(samples)
                report["search_http"] = searches
                ids = [row["mediaId"] for row in session.post(base_url + "/generated/search", json={}, timeout=30).json()["items"]]
                thumbnails = []
                for image_id in ids:
                    start = time.perf_counter()
                    response = session.get(base_url + f"/generated/media/{image_id}/thumbnail", timeout=30)
                    response.raise_for_status()
                    if not response.content.startswith(b"\x89PNG"):
                        raise ValueError("Invalid thumbnail response")
                    thumbnails.append((time.perf_counter() - start) * 1000)
                report["thumbnail_http"] = distribution(thumbnails)
                def concurrent_request(index):
                    client = requests.Session()
                    client.trust_env = False
                    client.headers.update(session.headers)
                    start = time.perf_counter()
                    with client:
                        response = client.post(base_url + "/generated/search", json=list(cases.values())[index % len(cases)], timeout=30)
                        response.raise_for_status()
                    return (time.perf_counter() - start) * 1000
                start = time.perf_counter()
                with ThreadPoolExecutor(max_workers=16) as pool:
                    samples = list(pool.map(concurrent_request, range(160)))
                report["concurrent_16_search"] = distribution(samples) | {"wall_seconds": time.perf_counter() - start}
                report["http_memory_peak"] = sampler.peak
            emit(stage="http_complete", label=label, search_p95_ms={k: round(v["p95_ms"], 2) for k, v in searches.items()})
            job_ids = []
            for index in range(12):
                response = session.post(base_url + "/generated/jobs", json={"preset": "fixture", "parameters": {}},
                    headers={"Idempotency-Key": f"benchmark-{label}-{index:04d}"}, timeout=10)
                response.raise_for_status()
                job_ids.append(response.json()["id"])
            deadline = time.monotonic() + 240
            while True:
                rows = [session.get(base_url + "/generated/jobs/" + identifier, timeout=10).json() for identifier in job_ids]
                completed = sum(row["state"] == "completed" for row in rows)
                emit(stage="jobs", label=label, completed=completed, total=len(rows))
                if all(row["state"] in ("completed", "failed", "cancelled") for row in rows):
                    break
                if time.monotonic() > deadline:
                    raise TimeoutError("The mock generation queue did not drain")
                time.sleep(2)
            with closing(sqlite3.connect(root / ("library-" + label) / "generated.sqlite")) as db:
                placeholders = ",".join("?" for _ in job_ids)
                rows = db.execute(f"SELECT created,submitted,updated,state FROM generation_jobs WHERE id IN ({placeholders})", job_ids).fetchall()
            report["mock_job_queue"] = {"count": len(rows), "states": [row[3] for row in rows],
                "wait": distribution([(row[1] - row[0]) * 1000 for row in rows]),
                "total": distribution([(row[2] - row[0]) * 1000 for row in rows]), "mock_gpu_seconds": .2}
            with closing(sqlite3.connect(root / ("library-" + label) / "generated.sqlite")) as db:
                control["syncHead"] = db.execute("SELECT MAX(seq) FROM sync_changes").fetchone()[0]
                control["catalogCount"] = db.execute("SELECT COUNT(*) FROM images WHERE state='ready'").fetchone()[0]
            save(root / "control.json", control)
            save(root / (label + ".json"), report)
            emit(stage="ready_for_flutter", label=label, control=str(root / "control.json"))
            while not (root / (label + ".stop")).exists():
                time.sleep(1)
        finally:
            if worker_pid and worker_pid != process.pid:
                try:
                    os.kill(worker_pid, signal.SIGTERM)
                except OSError:
                    pass
            process.terminate()
            try:
                process.wait(15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            session.close()
            log.close()


def compare(root, label):
    import importlib.util
    check_root(root)
    reference = json.loads((root / "baseline-prefix.json").read_text(encoding="utf-8"))
    path = root / "baseline_library.py"
    if hashlib.sha256(path.read_bytes()).hexdigest() != reference["source_sha256"]["server/services/generated_library.py"]:
        raise ValueError("Baseline importer source hash mismatch")
    spec = importlib.util.spec_from_file_location("benchmark_baseline_library", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    library = module.GeneratedLibrary(root / "source", root / ("library-" + label))
    attempts = []
    original_lock = library._worker_lock
    @contextmanager
    def observed_lock():
        with original_lock() as acquired:
            attempts.append(acquired)
            yield acquired
    library._worker_lock = observed_lock
    samples = []
    while len(samples) < 3:
        started = time.perf_counter()
        library.scan()
        if attempts[-1]:
            samples.append(time.perf_counter() - started)
        else:
            time.sleep(.1)
    reference["unchanged_scan_30000_same_catalog_seconds"] = samples
    save(root / "baseline-prefix.json", reference)
    emit(stage="baseline_unchanged_scan", seconds=samples)
    fast = GeneratedLibrary(root / "source", root / ("library-" + label))
    fast_attempts = []
    fast_lock = fast._worker_lock
    @contextmanager
    def observed_fast_lock():
        with fast_lock() as acquired:
            fast_attempts.append(acquired)
            yield acquired
    fast._worker_lock = observed_fast_lock
    fast_samples = []
    while len(fast_samples) < 3:
        started = time.perf_counter()
        fast.scan()
        if fast_attempts[-1]:
            fast_samples.append(time.perf_counter() - started)
        else:
            time.sleep(.1)
    report_path = root / (label + ".json")
    report = json.loads(report_path.read_text(encoding="utf-8"))
    report["unchanged_scan_30000_same_catalog_seconds"] = fast_samples
    save(report_path, report)
    emit(stage="improved_unchanged_scan", seconds=fast_samples)
    control = json.loads((root / "control.json").read_text(encoding="utf-8"))
    session = requests.Session()
    session.trust_env = False
    session.headers["Authorization"] = "Bearer " + control["token"]
    results = {}
    try:
        for mode in ("baseline", "improved"):
            response = session.post(control["baseUrl"] + "/performance/job-mode", params={"mode": mode}, timeout=10)
            response.raise_for_status()
            identifiers = []
            run = time.time_ns()
            for index in range(12):
                response = session.post(control["baseUrl"] + "/generated/jobs", json={"preset": "fixture", "parameters": {}},
                    headers={"Idempotency-Key": f"benchmark-comparison-{mode}-{run}-{index}"}, timeout=10)
                response.raise_for_status()
                identifiers.append(response.json()["id"])
            deadline = time.monotonic() + 240
            previous = -1
            while True:
                rows = [session.get(control["baseUrl"] + "/generated/jobs/" + identifier, timeout=10).json() for identifier in identifiers]
                completed = sum(row["state"] == "completed" for row in rows)
                if completed != previous:
                    emit(stage="job_comparison", mode=mode, completed=completed)
                    previous = completed
                if completed == len(rows):
                    break
                if time.monotonic() > deadline or any(row["state"] in ("failed", "cancelled") for row in rows):
                    raise RuntimeError("Benchmark comparison jobs did not complete")
                time.sleep(.5)
            with closing(sqlite3.connect(root / ("library-" + label) / "generated.sqlite")) as db:
                placeholders = ",".join("?" for _ in identifiers)
                rows = db.execute(f"SELECT created,submitted,updated FROM generation_jobs WHERE id IN ({placeholders})", identifiers).fetchall()
            results[mode] = {"wait": distribution([(r[1] - r[0]) * 1000 for r in rows]),
                             "total": distribution([(r[2] - r[0]) * 1000 for r in rows])}
        save(root / (label + ".job-comparison.json"), results)
    finally:
        session.post(control["baseUrl"] + "/performance/job-mode", params={"mode": "improved"}, timeout=10)
        session.close()
    with closing(sqlite3.connect(root / ("library-" + label) / "generated.sqlite")) as db:
        control["syncHead"] = db.execute("SELECT MAX(seq) FROM sync_changes").fetchone()[0]
        control["catalogCount"] = db.execute("SELECT COUNT(*) FROM images WHERE state='ready'").fetchone()[0]
    save(root / "control.json", control)
    emit(stage="comparison_finished", results=results)


def verify(root, label):
    fixture = check_root(root)
    library = GeneratedLibrary(root / "source", root / ("library-" + label))
    started = time.perf_counter()
    with closing(library.connect()) as db:
        integrity = [row[0] for row in db.execute("PRAGMA integrity_check")]
        if integrity != ["ok"]:
            raise RuntimeError("Benchmark database integrity check failed")
        rows = db.execute("SELECT digest,ext FROM images WHERE state='ready' ORDER BY digest").fetchall()
        counts = {table: db.execute("SELECT COUNT(*) FROM " + table).fetchone()[0]
                  for table in ("images", "generation_info", "prompt_search", "manual_tags", "generated_favorites")}
        if len(rows) < fixture["count"] or any(counts[table] != len(rows)
                for table in ("images", "generation_info", "prompt_search")):
            raise RuntimeError("Incomplete benchmark catalog")
        # Only the 30k fixture and its 100-image delta were manually tagged.
        if counts["manual_tags"] != (fixture["count"] + 100) * 2:
            raise RuntimeError("Manual tags changed during benchmarking")
        if counts["generated_favorites"] != math.ceil((fixture["count"] + 100) / 10):
            raise RuntimeError("Favorites changed during benchmarking")
    for index, row in enumerate(rows):
        original = library.root / "originals" / (row["digest"] + "." + row["ext"])
        data = original.read_bytes()
        if hashlib.sha256(data).hexdigest() != row["digest"]:
            raise RuntimeError("Original content hash mismatch")
        with Image.open(io.BytesIO(data)) as image:
            image.verify()
        thumbnail = library.root / "thumbs" / (row["digest"] + ".png")
        if not thumbnail.is_file():
            raise RuntimeError("Missing thumbnail")
        if index % 500 == 0:
            with Image.open(thumbnail) as image:
                image.load()
                if max(image.size) > 384:
                    raise RuntimeError("Oversized thumbnail")
    report = {"ready": len(rows), "counts": counts, "sqlite_integrity": integrity,
              "original_sha256_and_image_verify": len(rows), "thumbnail_existence": len(rows),
              "thumbnail_decode_samples": math.ceil(len(rows) / 500),
              "seconds": time.perf_counter() - started}
    save(root / (label + ".verification.json"), report)
    emit(stage="verified", **report)


def clean(root):
    check_root(root)
    if root.parent.name != ".dart_tool" or root.parent.parent.resolve() != Path.cwd().resolve():
        raise ValueError("Cleanup is restricted to this workspace's .dart_tool fixture")
    for path in root.iterdir():
        if path.is_dir() and (path.name in ("source", "templates") or path.name.startswith(("library-", "delta-", "service-", "xsaved-"))):
            if path.resolve().parent != root.resolve() or path.is_symlink():
                raise ValueError("Unexpected fixture path")
            shutil.rmtree(path)
    (root / "control.json").unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("prepare", "measure", "serve", "compare", "verify", "clean"))
    parser.add_argument("--root", type=Path, default=Path(".dart_tool/performance30k"))
    parser.add_argument("--count", type=int, default=30000)
    parser.add_argument("--label", default="baseline")
    parser.add_argument("--port", type=int, default=18880)
    parser.add_argument("--no-serve", action="store_true", help="Measure ingestion without starting the HTTP server")
    args = parser.parse_args()
    root = args.root.resolve()
    if not args.label.replace("-", "").isalnum():
        raise ValueError("Use an alphanumeric measurement label")
    if args.action == "prepare":
        prepare(root, args.count)
    elif args.action == "measure":
        measure(root, args.label, args.port, serve=not args.no_serve)
    elif args.action == "compare":
        compare(root, args.label)
    elif args.action == "serve":
        check_root(root)
        report = json.loads((root / (args.label + ".json")).read_text(encoding="utf-8"))
        serve_and_measure(root, args.label, args.port, report)
    elif args.action == "verify":
        verify(root, args.label)
    else:
        clean(root)


if __name__ == "__main__":
    main()
