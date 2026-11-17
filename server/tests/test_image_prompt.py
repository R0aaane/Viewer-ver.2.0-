import io
import json
import tempfile
import threading
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch, MagicMock

import requests
from fastapi import FastAPI
from PIL import Image
from server.api.routes_image_prompt import router
from server.services.image_prompt_service import ImagePromptService, merge, prompt_for, document_key
from server.tests.test_routes_generated import serve


def picture():
    out = io.BytesIO()
    Image.new('RGB', (32, 48), 'red').save(out, format='PNG')
    return out.getvalue()


class ImagePromptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.service = ImagePromptService(Path(self.temp.name), num_gpu=0)
        self.addCleanup(self.service.close)
        self.qwen = patch.object(self.service, '_qwen', return_value={'appearance': ['blue eyes'], 'pose': ['standing']})
        self.wd = patch.object(self.service, '_wd', return_value=[{'name': 'blue_eyes', 'category': 0, 'confidence': .95}])
        self.http = patch.object(self.service.http, 'post')
        for mock in (self.qwen, self.wd, self.http):
            mock.start(); self.addCleanup(mock.stop)

    def completed(self, job):
        for _ in range(200):
            result = self.service.get_job(job['id'])
            if result['state'] != 'running': return result
            time.sleep(.01)
        self.fail('analysis did not complete')

    def test_merge_dedupe_confidence_and_review_conflicts(self):
        tags, warnings = merge({'appearance': ['blue eyes', 'red hair']}, [
            {'name': 'blue_eyes', 'category': 0, 'confidence': .9},
            {'name': 'blue_hair', 'category': 0, 'confidence': .7},
            {'name': 'general', 'category': 9, 'confidence': .98}])
        self.assertEqual(len(tags), 4)
        self.assertEqual(tags[0]['sources'], ['qwen3-vl', 'wd14'])
        self.assertEqual(tags[0]['confidence'], .9)
        self.assertEqual(len(warnings), 1)
        self.assertNotIn('general', prompt_for(tags, ['rating']))
        self.assertEqual(prompt_for(tags, ['appearance', 'rating']), '')

    def test_manual_edits_survive_reanalysis_and_restart(self):
        job = self.completed(self.service.submit('pdf-source', 2, picture()))
        self.assertEqual(job['state'], 'completed')
        key = document_key('pdf-source', 2)
        data = job['result'] | {'tags': [{'text': 'manual edit', 'category': 'pose', 'enabled': True}]}
        self.assertEqual(self.service.save(key, 0, data), 1)
        self.completed(self.service.submit('pdf-source', 2, picture()))
        self.assertEqual(self.service.document(key)['document']['tags'][0]['text'], 'manual edit')
        with self.assertRaises(ValueError): self.service.save(key, 0, data)
        self.assertNotEqual(key, document_key('pdf-source', 1))
        reopened = ImagePromptService(Path(self.temp.name), num_gpu=0)
        try: self.assertEqual(reopened.document(key)['version'], 1)
        finally: reopened.close()

    def test_busy_failure_and_invalid_image(self):
        gate = threading.Event()
        with patch.object(self.service, '_qwen', side_effect=lambda *args: gate.wait(3) or {}):
            job = self.service.submit('source', 1, picture())
            try:
                with self.assertRaises(BlockingIOError): self.service.submit('other', 1, picture())
            finally: gate.set()
            self.completed(job)
        with self.assertRaises(OSError): self.service.submit('source', 1, b'bad image')
        with patch.object(self.service, '_qwen', side_effect=requests.ConnectionError('offline')):
            job = self.completed(self.service.submit('source', 1, picture()))
            self.assertEqual(job['state'], 'failed')
            self.assertIn('Ollama', job['error'])

    def test_gpu_guard_failure_does_not_run_qwen(self):
        self.service.num_gpu = -1
        with patch('server.services.image_prompt_service.free_comfy', side_effect=ValueError('guard missing')), \
             patch('server.services.image_prompt_service.unload_ollama'):
            job = self.completed(self.service.submit('guard-failed', 1, picture()))
            self.assertEqual(job['state'], 'failed')
            self.assertIn('guard', job['error'])
            self.service._qwen.assert_not_called()

    def test_qwen_uses_explicit_gpu_and_disables_thinking(self):
        response = MagicMock()
        response.__enter__.return_value = response
        response.iter_lines.return_value = [json.dumps({'message':{'content':'{"appearance":["blue eyes"]}'},'done':True}).encode()]
        self.service.num_gpu = -1
        self.service.model = 'qwen3-vl:8b'
        with patch.object(self.service.http, 'post', return_value=response) as post:
            result = ImagePromptService._qwen(self.service, picture(), 'test')
            self.assertEqual(result['appearance'], ['blue eyes'])
            self.assertFalse(post.call_args.kwargs['json']['think'])
            self.assertEqual(post.call_args.kwargs['json']['options']['num_gpu'], -1)

    def test_failed_gpu_unload_keeps_browser_generation_blocked(self):
        self.service.num_gpu = -1
        with patch('server.services.image_prompt_service.free_comfy'), \
             patch('server.services.image_prompt_service.unload_ollama', side_effect=TimeoutError('not unloaded')):
            job = self.completed(self.service.submit('unload-failed', 1, picture()))
            self.assertEqual(job['state'], 'failed')
            self.assertTrue(self.service.gpu_path.with_suffix('.owner.json').exists())

    def test_authenticated_api_save_and_conflict(self):
        app = FastAPI(); app.include_router(router)
        app.state.settings = SimpleNamespace(auth_token='test-secret')
        app.state.image_prompt = self.service
        headers = {'Authorization': 'Bearer test-secret'}
        with serve(app) as port:
            url = f'http://127.0.0.1:{port}/image-prompt'
            self.assertEqual(requests.get(url+'/configuration',timeout=3).status_code,401)
            response = requests.post(url+'/jobs',headers=headers,data={'source':'pdf','page':3},files={'image':('p.png',picture())},timeout=3)
            self.assertEqual(response.status_code,202,response.text)
            job = self.completed(response.json())
            edit = {'source':'pdf','page':3,'expectedVersion':0,'jobId':job['id'],
                    'tags':job['result']['tags'],'disabledCategories':['pose']}
            result = requests.put(url+'/document',headers=headers,json=edit,timeout=3)
            self.assertEqual(result.status_code,200,result.text)
            self.assertEqual(result.json()['document']['prompt'],'blue eyes')
            self.assertEqual(requests.put(url+'/document',headers=headers,json=edit,timeout=3).status_code,409)
            edit['page']=4
            self.assertEqual(requests.put(url+'/document',headers=headers,json=edit,timeout=3).status_code,422)
            self.assertEqual(requests.post(url+'/jobs',headers=headers,data={'source':'pdf','page':3},files={'image':('bad.png',b'bad')},timeout=3).status_code,422)
