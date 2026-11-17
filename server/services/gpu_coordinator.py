"""Cross-process GPU handoff. Owner marker also gates direct ComfyUI submissions."""
import json
import os
import sqlite3
import time
from pathlib import Path

import requests


class GpuLease:
    def __init__(self, path):
        self.path = Path(path)
        self.owner = self.path.with_suffix('.owner.json')
        self.db = None

    def acquire(self, mode):
        if self.db is not None: return True
        self.path.parent.mkdir(parents=True, exist_ok=True)
        db = sqlite3.connect(self.path, timeout=0, check_same_thread=False)
        try: db.execute('BEGIN IMMEDIATE')
        except sqlite3.OperationalError as exc:
            db.close()
            if "locked" not in str(exc).lower(): raise
            return False
        self.db = db
        try: self.mode(mode)
        except Exception:
            self.release(); raise
        return True

    def mode(self, mode):
        temporary = self.owner.with_suffix('.tmp')
        temporary.write_text(json.dumps({'mode': mode, 'pid': os.getpid()}), encoding='utf-8')
        temporary.replace(self.owner)

    def release(self, clear=True):
        if self.db is None: return
        try:
            if clear: self.owner.unlink(missing_ok=True)
        finally:
            self.db.rollback(); self.db.close(); self.db = None


def unload_ollama(http, url='http://127.0.0.1:11434', model=None):
    try:
        models = http.get(url + '/api/ps', timeout=(2, 5))
        models.raise_for_status()
    except requests.ConnectionError as exc:
        if isinstance(exc, requests.Timeout): raise
        # A refused loopback socket has no server/model to unload.
        import socket
        from urllib.parse import urlsplit
        parsed = urlsplit(url)
        try:
            with socket.create_connection((parsed.hostname, parsed.port or 80), timeout=1): pass
        except ConnectionRefusedError: return
        raise
    targets = [model] if model else ['qwen3-vl:8b', 'qwen3-vl:8b-instruct']
    resident = {m.get('name') for m in models.json().get('models', [])}
    if not resident.intersection(targets): return
    for target in targets:
        if target not in resident: continue
        response = http.post(url + '/api/generate', json={'model': target, 'keep_alive': 0}, timeout=(2, 30))
        response.raise_for_status()
    for _ in range(30):
        response = http.get(url + '/api/ps', timeout=(2, 5))
        response.raise_for_status()
        if not {m.get('name') for m in response.json().get('models', [])}.intersection(targets): return
        time.sleep(.2)
    raise TimeoutError('QwenのVRAM解放を確認できません。GPU処理を再開しません')


def free_comfy(http, url, progress, timeout=600):
    deadline = time.monotonic() + timeout
    progress('waiting_comfy')
    while True:
        try:
            response = http.get(url + '/queue', timeout=(2, 5)); response.raise_for_status()
        except requests.ConnectionError as exc:
            if isinstance(exc, requests.Timeout): raise
            import socket
            from urllib.parse import urlsplit
            parsed = urlsplit(url)
            try:
                with socket.create_connection((parsed.hostname, parsed.port or 80), timeout=1): pass
            except ConnectionRefusedError: return
            raise
        queue = response.json()
        if not queue.get('queue_running') and not queue.get('queue_pending'): break
        if time.monotonic() >= deadline: raise TimeoutError('ComfyUIの生成完了待ちがタイムアウトしました')
        time.sleep(1)
    guard = http.get(url + '/pdf-viewer/gpu-guard', timeout=(2, 5))
    guard.raise_for_status()
    if guard.json().get('protocol') != 2: raise ValueError('ComfyUIのGPUガードを更新してください')
    progress('freeing_comfy')
    response = http.post(url + '/free', json={'unload_models': True, 'free_memory': True}, timeout=(2, 10))
    response.raise_for_status()
    for _ in range(90):
        response = http.get(url + '/system_stats', timeout=(2, 5)); response.raise_for_status()
        devices = [d for d in response.json().get('devices', []) if d.get('type') == 'cuda']
        guard = http.get(url + '/pdf-viewer/gpu-guard', timeout=(2, 5)); guard.raise_for_status()
        if guard.json().get('loadedModelCount') == 0 and (not devices or all(d.get('torch_vram_total', 0) <= 256 * 1024 * 1024 for d in devices)):
            return {'comfyLoadedModelCount': 0, 'comfyFreeBytes': min((d.get('vram_free', 0) for d in devices), default=0)}
        time.sleep(.5)
    raise TimeoutError('ComfyUIのモデル解放を確認できません。解析を開始しません')
