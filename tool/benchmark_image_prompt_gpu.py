"""Explicit opt-in GPU handoff/CPU comparison using a caller-provided PDF fixture."""
import argparse
import io
import json
import sqlite3
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import pypdfium2 as pdfium
import requests
from server.services.generated_library import GeneratedLibrary
from server.services.generation_jobs import GenerationJobs
from server.services.image_prompt_service import ImagePromptService
from server.services.gpu_coordinator import GpuLease


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--pdf', type=Path, required=True)
    parser.add_argument('--wd', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = root / '.dart_tool/image-prompt/gpu-benchmark'
    output.mkdir(parents=True, exist_ok=True)
    report_path = output / 'result.json'
    report = {'phase': 'starting'}
    def record(): report_path.write_text(json.dumps(report, indent=2), encoding='utf-8')
    http = requests.Session(); http.trust_env = False
    guard = http.get('http://127.0.0.1:8188/pdf-viewer/gpu-guard', timeout=5)
    guard.raise_for_status(); assert guard.json()['enabled']
    queue = http.get('http://127.0.0.1:8188/queue', timeout=5).json()
    assert not queue['queue_running'] and not queue['queue_pending'], 'ComfyUI busy'
    pdf = pdfium.PdfDocument(str(args.pdf))
    try:
        page = pdf[0]
        bitmap = page.render(scale=1280 / page.get_width())
        try:
            image = bitmap.to_pil().convert('RGB')
            buffer = io.BytesIO(); image.save(buffer, format='PNG'); payload = buffer.getvalue()
        finally: bitmap.close(); page.close()
    finally: pdf.close()
    report['imageSize'] = list(image.size)
    lock_path = root / 'data/gpu_coordination.sqlite'
    source = output / 'source'; source.mkdir(exist_ok=True)
    library = GeneratedLibrary(source, output / 'generated')
    presets = json.loads((root / 'data/local_generation/presets.json').read_text(encoding='utf-8'))
    preset = next(p for p in presets if p['id'] == 'txt2img')
    for node in preset['workflow'].values():
        if node['class_type'] == 'SaveImage': node['inputs']['filename_prefix'] = 'PDFViewer_Benchmark/gpu_handoff'
    preset_file = output / 'presets.json'; preset_file.write_text(json.dumps([preset]), encoding='utf-8')
    jobs = GenerationJobs(library, 'http://127.0.0.1:8188', preset_file, gpu_path=lock_path)
    jobs.start()
    services = []
    def generation(name):
        return jobs.create(f'benchmark-{name}-{time.time_ns()}', 'txt2img', {'positive': 'sunny landscape, mountains, trees, no humans', 'steps': 6})
    def wait_generation(job):
        deadline = time.monotonic() + 300
        while time.monotonic() < deadline:
            current = jobs.get(job['id'])
            if current['state'] == 'failed': raise RuntimeError(current['error'])
            if current['state'] == 'completed': return current
            time.sleep(.5)
        raise TimeoutError('benchmark generation timeout')
    try:
        report['phase'] = 'warming_comfy'; record()
        warm = generation('warm'); wait_generation(warm)
        stats = http.get('http://127.0.0.1:8188/system_stats', timeout=5).json()
        report['comfyCachedBytesBeforeAnalysis'] = max((d.get('torch_vram_total',0) for d in stats['devices']), default=0)
        report['comfyFreeBytesBeforeAnalysis'] = min((d.get('vram_free',0) for d in stats['devices']), default=0)
        report['comfyLoadedModelsBeforeAnalysis'] = http.get('http://127.0.0.1:8188/pdf-viewer/gpu-guard', timeout=5).json()['loadedModelCount']
        for mode, gpu in [('gpu', -1), ('cpu', 0)]:
            report['phase'] = mode; record()
            service = ImagePromptService(output / mode, wd_directory=args.wd, num_gpu=gpu, gpu_path=lock_path)
            services.append(service)
            cpu_lease = GpuLease(lock_path)
            if mode == 'cpu': assert cpu_lease.acquire('analysis'), 'GPU lock busy'
            try:
                job = service.submit('benchmark-pdf', 1, payload)
                peak = 0; max_comfy_models = 0; max_comfy_during_qwen = 0; rejected = False; pending = None; blocked = False
                deadline = time.monotonic() + 1000
                while time.monotonic() < deadline:
                    current = service.get_job(job['id'])
                    if current['state'] == 'failed': raise RuntimeError(current['error'])
                    if current['state'] == 'completed': break
                    if mode == 'gpu' and current['stage'] in ('loading_qwen','analyzing_qwen'):
                        if not rejected:
                            rejected = http.post('http://127.0.0.1:8188/prompt', json={'prompt':{}}, timeout=5).status_code == 503
                            pending = generation('after-analysis')
                        if pending and jobs.get(pending['id'])['state'] == 'queued': blocked = True
                        max_comfy_models = max(max_comfy_models, http.get('http://127.0.0.1:8188/pdf-viewer/gpu-guard', timeout=5).json()['loadedModelCount'])
                        stats = http.get('http://127.0.0.1:8188/system_stats', timeout=5).json()
                        max_comfy_during_qwen = max(max_comfy_during_qwen, max((d.get('torch_vram_total',0) for d in stats['devices']), default=0))
                    models = http.get('http://127.0.0.1:11434/api/ps', timeout=5).json().get('models',[])
                    peak = max(peak, max((m.get('size_vram',0) for m in models if m['name'].startswith('qwen3-vl:8b')),default=0))
                    time.sleep(.5)
                else: raise TimeoutError('benchmark analysis timeout')
                result = current['result']
                report[mode] = {'timings':result['timings'], 'imageSha256':result['imageSha256'], 'tagCount':len(result['tags']), 'qwenPeakBytes':peak, 'handoff':result['handoff'], 'model':result['models']['qwen']}
                if mode == 'gpu':
                    assert max_comfy_models == 0, 'Comfy models remain during Qwen'
                    report['maxComfyLoadedModelsDuringQwen'] = max_comfy_models
                    assert peak > 0, 'Qwen did not use GPU'
                    assert rejected and blocked, 'GPU exclusion was not observed'
                    assert max_comfy_during_qwen <= 256*1024*1024, 'Comfy tensors remain during Qwen'
                    report['guardRejectedDirectPrompt'] = rejected
                    report['appGenerationWaited'] = blocked
                    report['maxComfyTensorBytesDuringQwen'] = max_comfy_during_qwen
                    models = http.get('http://127.0.0.1:11434/api/ps',timeout=5).json()['models']
                    report['qwenUnloadedBeforeGeneration'] = not any(m['name'].startswith('qwen3-vl:8b') for m in models)
                    assert report['qwenUnloadedBeforeGeneration']
                    assert pending is not None
                    wait_generation(pending)
                    report['generationResumedAndCompleted'] = True
                record()
            finally: cpu_lease.release()
        assert report['gpu']['imageSha256'] == report['cpu']['imageSha256']
        report['speedup'] = round(report['cpu']['timings']['totalSeconds'] / report['gpu']['timings']['totalSeconds'], 2)
        report['phase'] = 'completed'; record()
        print(json.dumps(report, indent=2))
    except Exception as exc:
        report['phase'] = 'failed'; report['error'] = str(exc); record(); raise
    finally:
        for service in services: service.close()
        jobs.close(); http.close()


if __name__ == '__main__': main()
