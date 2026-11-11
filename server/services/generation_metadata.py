"""Read ComfyUI graph data without executing nodes or relying on node numbers."""
import json
from PIL import Image


def read_generation(path):
    with Image.open(path) as image:
        raw = {k: image.info.get(k) for k in ("workflow", "prompt")}
        # ComfyUI's WebP exporter uses prefixed EXIF values.
        for value in image.getexif().values():
            if isinstance(value, bytes):
                value = value.decode("utf-8", errors="replace")
            if isinstance(value, str):
                key, _, text = value.partition(":")
                if key.lower() in raw and raw[key.lower()] is None:
                    raw[key.lower()] = text.rstrip("\0")
        dimensions = [image.width, image.height]
    try:
        graph = json.loads(raw["prompt"] or "{}")
        samplers = _samplers(graph) if isinstance(graph, dict) else []
        # Invalid Unicode or non-finite numbers in extension metadata must not
        # block SQLite indexing, JSON responses, or other pending imports.
        json.dumps(samplers, ensure_ascii=False, allow_nan=False).encode("utf-8")
    except (TypeError, ValueError, RecursionError):
        samplers = []
    return raw, {"dimensions": dimensions, "samplers": samplers}


def _samplers(graph):
    def resolve(edge):
        if not isinstance(edge, list) or len(edge) != 2 or not isinstance(edge[0], (int, str)):
            return None, {}
        node = graph.get(str(edge[0]))
        if not isinstance(node, dict) or not isinstance(node.get("inputs"), dict):
            return None, {}
        return node.get("class_type"), node["inputs"]

    def upstream(link, conditioning=False):
        todo = [link]
        seen = set()
        while todo:
            edge = todo.pop()
            if (not isinstance(edge, list) or len(edge) != 2 or
                    not isinstance(edge[0], (int, str)) or not isinstance(edge[1], int)):
                continue
            key = str(edge[0])
            kind, inputs = resolve(edge)
            visit = (key, str(edge[1]))
            if visit in seen or not isinstance(kind, str):
                continue
            seen.add(visit)
            yield kind, inputs
            if conditioning:
                # ControlNet has independent positive and negative outputs.
                if kind == "ControlNetApplyAdvanced" and edge[1] in (0, 1):
                    todo.append(inputs.get(("positive", "negative")[edge[1]]))
                else:
                    todo.extend(v for k, v in inputs.items() if k.startswith("conditioning"))
            else:
                todo.append(inputs.get("model"))

    def texts(link):
        values = []
        for kind, inputs in upstream(link, conditioning=True):
            if isinstance(kind, str) and kind.startswith("CLIPTextEncode"):
                for key in ("text", "text_g", "text_l"):
                    if isinstance(inputs.get(key), str) and inputs[key] not in values:
                        values.append(inputs[key])
        return "\n".join(values)

    result = []
    for key, node in graph.items():
        if not isinstance(node, dict) or node.get("class_type") not in (
            "KSampler", "KSamplerAdvanced", "SamplerCustom", "SamplerCustomAdvanced"
        ):
            continue
        inputs = node.get("inputs")
        if not isinstance(inputs, dict):
            continue
        if node["class_type"].startswith("SamplerCustom"):
            inputs = dict(inputs)
            for field, types, keys in (
                ("guider", ("CFGGuider", "BasicGuider"), ("model", "positive", "negative", "cfg", "conditioning")),
                ("sampler", ("KSamplerSelect",), ("sampler_name",)),
                ("sigmas", ("BasicScheduler",), ("scheduler", "steps")),
                ("noise", ("RandomNoise",), ("noise_seed",)),
            ):
                kind, source = resolve(inputs.get(field))
                if kind in types:
                    inputs.update({k: source[k] for k in keys if k in source})
            if "conditioning" in inputs:
                inputs.setdefault("positive", inputs["conditioning"])
        sampler = {"node": key, "positive": texts(inputs.get("positive")),
                   "negative": texts(inputs.get("negative")), "lora": [], "checkpoint": []}
        for name in ("seed", "noise_seed", "steps", "cfg", "sampler_name", "scheduler"):
            value = inputs.get(name)
            if isinstance(value, (int, float, str)):
                if name in ("seed", "noise_seed"):
                    sampler["seed"] = str(value)
                else:
                    sampler[name] = value
        for kind, values in upstream(inputs.get("model")):
            if isinstance(values.get("ckpt_name"), str):
                sampler["checkpoint"].append(values["ckpt_name"])
            if isinstance(values.get("lora_name"), str):
                sampler["lora"].append({k: values[k] for k in ("lora_name", "strength_model", "strength_clip")
                                        if isinstance(values.get(k), (str, int, float))})
        result.append(sampler)
    return result
