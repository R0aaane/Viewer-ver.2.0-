import json
from dataclasses import replace
from pathlib import Path
import uuid

FIELDS = ("data_dir", "sqlite_path", "thumbs_dir", "media_roots", "port", "generated_library_dir",
          "comfy_output_dir", "comfy_presets_path", "generation_timeout_seconds", "xviewer_saved_images_dir")
PATHS = {"data_dir", "sqlite_path", "thumbs_dir", "generated_library_dir", "comfy_output_dir",
         "comfy_presets_path", "xviewer_saved_images_dir"}


def persist_host_settings(settings):
    snapshot = {}
    for name in FIELDS:
        value = getattr(settings, name, None)
        snapshot[name] = str(value) if isinstance(value, Path) else value
    path = settings.data_dir / ("host_settings." + uuid.uuid4().hex + ".part")
    try:
        path.write_text(json.dumps(snapshot, ensure_ascii=False), encoding="utf-8")
        path.replace(settings.data_dir / "host_settings.json")
    finally:
        path.unlink(missing_ok=True)


def load_host_settings(base, data_dir):
    path = data_dir / "host_settings.json"
    if not path.is_file():
        raise ValueError("Start the updated host once, then stop it before maintenance")
    values = json.loads(path.read_text(encoding="utf-8"))
    if Path(values["data_dir"]).resolve() != data_dir.resolve():
        raise ValueError("Host snapshot settings belong to another data directory")
    selected = {name: Path(value) if name in PATHS and value is not None else value
                for name, value in values.items() if name in FIELDS}
    return replace(base, **selected)
