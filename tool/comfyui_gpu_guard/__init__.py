"""Reject new prompts during PDF Viewer GPU analysis; never interrupt existing work."""
import json
import os
from pathlib import Path
from aiohttp import web
from server import PromptServer
from comfy import model_management

config = Path(__file__).with_name('config.json')
lock_path = os.environ.get('PDF_VIEWER_GPU_LOCK_PATH')
if not lock_path and config.is_file():
    lock_path = json.loads(config.read_text(encoding='utf-8'))['lockPath']
if lock_path:
    marker = Path(lock_path).with_suffix('.owner.json')

    @web.middleware
    async def pdf_viewer_gpu_guard(request, handler):
        if request.method == 'POST' and request.path in ('/prompt', '/api/prompt'):
            try:
                owner = json.loads(marker.read_text(encoding='utf-8'))
            except FileNotFoundError:
                owner = {'mode': 'generation'}
            except (ValueError, OSError):
                return web.json_response({'error': 'PDF Viewer GPU handoff state unavailable; retry later'}, status=503)
            if owner.get('mode') != 'generation':
                return web.json_response({'error': 'PDF Viewer image analysis is using the GPU; retry after analysis finishes'}, status=503)
        return await handler(request)

    PromptServer.instance.app.middlewares.append(pdf_viewer_gpu_guard)
    @PromptServer.instance.routes.get('/pdf-viewer/gpu-guard')
    async def guard_status(request):
        return web.json_response({'enabled': True, 'protocol': 2, 'loadedModelCount': len(model_management.current_loaded_models)})

NODE_CLASS_MAPPINGS = {}
NODE_DISPLAY_NAME_MAPPINGS = {}
