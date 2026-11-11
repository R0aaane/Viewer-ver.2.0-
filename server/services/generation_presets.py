"""Host-owned API workflows and explicitly editable scalar inputs."""
import copy
import json
import math
from pathlib import Path


class GenerationPresets:
    def __init__(self, path: Path):
        entries = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(entries, list) or not entries:
            raise ValueError("Preset file must contain a nonempty array")
        self.entries = {}
        for entry in entries:
            if not isinstance(entry, dict):
                raise ValueError("Each preset must be an object")
            identifier = entry["id"]
            if not isinstance(identifier, str) or not identifier or identifier in self.entries:
                raise ValueError("Preset IDs must be unique strings")
            graph = entry["workflow"]
            if not isinstance(graph, dict) or not graph:
                raise ValueError("Export the workflow in ComfyUI API format")
            for node in graph.values():
                if (not isinstance(node, dict) or not isinstance(node.get("class_type"), str)
                        or not isinstance(node.get("inputs"), dict)):
                    raise ValueError("Invalid API workflow node")
            parameters = entry["parameters"]
            if not isinstance(parameters, dict):
                raise ValueError("Preset parameters must be an object")
            for name, spec in parameters.items():
                if not isinstance(spec, dict):
                    raise ValueError("Parameter definitions must be objects")
                target = graph[str(spec["node"])]["inputs"][spec["input"]]
                if isinstance(target, (list, dict)):
                    raise ValueError("Editable inputs must be scalar values, not graph links")
                kind = spec["type"]
                if kind not in ("text", "integer", "number", "choice"):
                    raise ValueError("Unsupported parameter type")
                if kind == "choice" and not spec.get("choices"):
                    raise ValueError("Choices must be explicitly allowed")
                if kind in ("integer", "number") and spec["min"] > spec["max"]:
                    raise ValueError("Invalid numeric limits")
                self.validate(name, spec, spec["default"])
            self.entries[identifier] = entry

    @staticmethod
    def validate(name, spec, value):
        kind = spec["type"]
        if kind == "text":
            valid = isinstance(value, str) and len(value) <= spec.get("maxLength", 8192)
        elif kind == "choice":
            valid = isinstance(value, str) and value in spec["choices"]
        else:
            valid = type(value) in ((int,) if kind == "integer" else (int, float))
            valid = valid and spec["min"] <= value <= spec["max"] and math.isfinite(value)
            if valid and "step" in spec:
                valid = spec["step"] > 0 and math.isclose(
                    (value - spec["min"]) / spec["step"], round((value - spec["min"]) / spec["step"]))
        if not valid:
            raise ValueError(f"Invalid parameter: {name}")
        return value

    def public(self):
        return [{"id": key, "name": item.get("name", key), "parameters": {
            name: {k: v for k, v in spec.items() if k not in ("node", "input")}
            for name, spec in item["parameters"].items()}} for key, item in self.entries.items()]

    def build(self, identifier, values):
        if identifier not in self.entries:
            raise ValueError("Unknown workflow preset")
        preset = self.entries[identifier]
        specs = preset["parameters"]
        if values.keys() - specs.keys():
            raise ValueError("Parameter is not editable in this preset")
        graph = copy.deepcopy(preset["workflow"])
        for name, spec in specs.items():
            graph[str(spec["node"])]["inputs"][spec["input"]] = self.validate(
                name, spec, values.get(name, spec["default"]))
        return graph
