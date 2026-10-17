"""Build an allowlisted host bundle; never package local data or configuration."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
import zipfile


def package(root: Path, output: Path, revision: str, python_version: str | None = None) -> Path:
    version = re.search(r"^version:\s*(\S+)", (root / "pubspec.yaml").read_text(encoding="utf-8"), re.M)[1]
    files = {"requirements.txt": root / "requirements.txt"}
    for directory, suffixes in [("server", {".py"}), ("build/web", None), ("wheelhouse", {".whl"})]:
        for path in (root / directory).rglob("*"):
            relative = path.relative_to(root)
            if path.is_file() and "tests" not in relative.parts and "__pycache__" not in relative.parts:
                if suffixes is None or path.suffix in suffixes:
                    files[relative.as_posix()] = path
    files["assets/config/tag_aliases.json"] = root / "assets/config/tag_aliases.json"
    if "build/web/index.html" not in files or not any(name.startswith("wheelhouse/") for name in files):
        raise ValueError("Web build and Windows Python wheels are required")
    manifest = {"format": 1, "dataEpoch": 1, "version": version, "revision": revision,
                "python": python_version or f"{sys.version_info.major}.{sys.version_info.minor}", "platform": "win-amd64",
                "files": {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in files.items()}}
    output.mkdir(parents=True, exist_ok=True)
    archive = output / "host.zip"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
        for name, path in files.items():
            bundle.write(path, name)
        bundle.writestr("release.json", json.dumps(manifest))
    (output / "host.zip.sha256").write_text(hashlib.sha256(archive.read_bytes()).hexdigest(), encoding="utf-8")
    return archive


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--revision", required=True)
    args = parser.parse_args()
    package(Path.cwd(), Path("dist"), args.revision)
