import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch
import requests
from server.services.gpu_coordinator import GpuLease, free_comfy, unload_ollama


def response(data, status=200):
    result = Mock()
    result.json.return_value = data
    if status >= 400:
        reply = requests.Response(); reply.status_code = status
        result.raise_for_status.side_effect = requests.HTTPError(response=reply)
    return result


class GpuCoordinatorTests(unittest.TestCase):
    def test_exclusive_handoff_and_failure_marker(self):
        with tempfile.TemporaryDirectory() as temp:
            first = GpuLease(Path(temp)/'gpu.sqlite')
            second = GpuLease(first.path)
            self.assertTrue(first.acquire('analysis'))
            try: self.assertFalse(second.acquire('generation'))
            finally: first.release(clear=False)
            self.assertEqual(json.loads(first.owner.read_text(encoding='utf-8'))['mode'], 'analysis')
            self.assertTrue(second.acquire('handoff'))
            second.mode('generation')
            self.assertEqual(json.loads(second.owner.read_text(encoding='utf-8'))['mode'], 'generation')
            second.release()
            self.assertFalse(first.owner.exists())

    def test_comfy_drains_queue_then_confirms_tensor_release(self):
        http = Mock()
        http.get.side_effect = [response({'queue_running': [1]}), response({'queue_running': [],'queue_pending': []}),
            response({'protocol':2}), response({'devices':[{'type':'cuda','torch_vram_total':0}]}), response({'loadedModelCount':1}),
            response({'devices':[{'type':'cuda','torch_vram_total':0}]}), response({'loadedModelCount':0})]
        stages = []
        with patch('server.services.gpu_coordinator.time.sleep'):
            free_comfy(http,'http://fixture',stages.append)
        self.assertEqual(stages,['waiting_comfy','freeing_comfy'])
        self.assertEqual(http.post.call_count,1)
        self.assertEqual(http.post.call_args.args[0],'http://fixture/free')

    def test_missing_guard_refuses_handoff(self):
        http = Mock()
        http.get.side_effect = [response({}),response({},404)]
        with self.assertRaises(requests.HTTPError): free_comfy(http,'http://fixture',lambda _:None)
        http.post.assert_not_called()

    def test_qwen_unload_waits_for_ps_confirmation(self):
        http = Mock()
        resident = {'models':[{'name':'qwen3-vl:8b','size_vram':123}]}
        http.get.side_effect = [response(resident),response(resident),response({'models':[]})]
        with patch('server.services.gpu_coordinator.time.sleep'):
            unload_ollama(http)
        self.assertEqual(http.get.call_count,3)
        self.assertEqual(http.post.call_args.kwargs['json']['keep_alive'],0)
