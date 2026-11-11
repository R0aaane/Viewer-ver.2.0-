"""Offline, verified snapshots. Restoration always publishes into a new directory."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import sqlite3
from contextlib import closing
from dataclasses import asdict
from tempfile import TemporaryDirectory
import time
import uuid

from server.services.maintenance import host_lock
from server.services.protected_backup import protect, unprotect


def checksum(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def database_copy(source, destination):
    with closing(sqlite3.connect(source)) as src, closing(sqlite3.connect(destination)) as dst:
        src.backup(dst)
        if dst.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise ValueError("Database integrity check failed")


def staging_for(destination):
    destination = destination.resolve()
    if destination.exists():
        raise ValueError("Choose a new destination directory")
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = destination.with_name(destination.name + ".staging-" + uuid.uuid4().hex)
    staging.mkdir()
    return destination, staging


def discard_staging(staging, destination):
    if (staging.resolve().parent != destination.resolve().parent
            or not staging.name.startswith(destination.name + ".staging-")):
        raise ValueError("Unsafe staging directory")
    if staging.exists():
        shutil.rmtree(staging)


def create_backup(settings, destination):
    destination = destination.resolve()
    roots = [Path(p).resolve() for p in settings.media_roots]
    if settings.generated_library_dir:
        roots.append(settings.generated_library_dir.resolve())
    roots.append(settings.xviewer_saved_images_dir.resolve())
    for root in [settings.data_dir.resolve(), *roots]:
        if destination.is_relative_to(root) or root.is_relative_to(destination):
            raise ValueError("Backup destination must be separate from host data and media")
    destination, staging = staging_for(destination)
    try:
        with host_lock(settings.data_dir, exclusive=True), TemporaryDirectory() as temporary:
            scratch = Path(temporary)
            manifest = {"format": 1, "created": time.time(), "files": [],
                        "settings": {key: str(value) if isinstance(value, Path) else value
                                     for key, value in asdict(settings).items() if key != "auth_token"}}

            def add(source, relative, database=False):
                if source.is_symlink() or bool(getattr(source.lstat(), "st_file_attributes", 0) & 0x400):
                    raise ValueError("Backup source contains a filesystem link")
                before = source.stat()
                plain = scratch / "database.sqlite" if database else source
                if database:
                    database_copy(source, plain)
                identifier = f"{len(manifest['files']):08d}.protected"
                digest = checksum(plain)
                if relative.startswith("generated/originals/") and source.stem != digest:
                    raise ValueError("Generated original checksum does not match its media ID")
                protect(plain, staging / identifier)
                after = source.stat()
                if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns) or digest != checksum(plain):
                    raise ValueError("A source file changed during backup")
                manifest["files"].append({"blob": identifier, "path": relative, "sha256": digest, "size": plain.stat().st_size})
                if database:
                    plain.unlink()

            def add_tree(root, relative):
                for path in sorted(root.rglob("*")):
                    if path.is_symlink() or bool(getattr(path.lstat(), "st_file_attributes", 0) & 0x400):
                        raise ValueError("Backup tree contains a filesystem link")
                    if path.is_file():
                        add(path, relative + "/" + path.relative_to(root).as_posix())

            if settings.sqlite_path.exists():
                add(settings.sqlite_path, "data/metadata.sqlite", True)
            devices = settings.data_dir / "device_tokens.sqlite"
            if devices.exists():
                add(devices, "data/device_tokens.sqlite", True)
            for index, raw in enumerate(settings.media_roots):
                root = Path(raw).resolve()
                if not root.is_dir():
                    raise ValueError("Configured media root is unavailable")
                add_tree(root, f"media/{index}")
            pdf_history = settings.data_dir / ".pdf-edit-backups"
            if pdf_history.is_dir():
                add_tree(pdf_history, "data/.pdf-edit-backups")
            if settings.xviewer_saved_images_dir.is_dir():
                add_tree(settings.xviewer_saved_images_dir, "saved-images")
            library = settings.generated_library_dir
            if library:
                with closing(sqlite3.connect(library / "generated.sqlite")) as catalog:
                    if catalog.execute("SELECT 1 FROM images WHERE state<>'ready' LIMIT 1").fetchone():
                        raise ValueError("Incomplete publication exists; run host repair before backup")
                    for digest, ext in catalog.execute("SELECT digest,ext FROM images"):
                        if not (library / "originals" / f"{digest}.{ext}").is_file():
                            raise ValueError("A catalog original is missing; restore it before backup")
                add(library / "generated.sqlite", "generated/generated.sqlite", True)
                for folder in ("originals", "thumbs"):
                    for path in sorted((library / folder).glob("*")):
                        if path.is_file():
                            add(path, "generated/" + path.relative_to(library).as_posix())
            if settings.comfy_presets_path:
                add(settings.comfy_presets_path, "config/presets.json")
            manifest_path = scratch / "manifest.json"
            manifest_path.write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
            protect(manifest_path, staging / "manifest.protected")
            staging.rename(destination)
        return len(manifest["files"])
    finally:
        discard_staging(staging, destination)


def repair_host(settings):
    from server.repositories.sqlite_store import SqliteStore
    from server.services.media_index_service import MediaIndexService
    from server.services.generated_library import GeneratedLibrary
    with host_lock(settings.data_dir, exclusive=True):
        if any(not Path(root).is_dir() for root in settings.media_roots):
            raise ValueError("Reconnect all media roots before rebuilding the index")
        if settings.generated_library_dir and not (settings.comfy_output_dir and settings.comfy_output_dir.is_dir()):
            raise ValueError("Reconnect the configured ComfyUI output directory before repair")
        store = SqliteStore(settings.sqlite_path)
        try:
            store.init_schema()
            MediaIndexService(store).rescan_configured_roots(settings.media_roots)
        finally:
            store.close()
        count = 0
        if settings.generated_library_dir:
            library = GeneratedLibrary(settings.comfy_output_dir, settings.generated_library_dir)
            library.scan()
            with library._worker_lock() as acquired, closing(library.connect()) as db:
                if not acquired:
                    raise RuntimeError("The generated importer is still running")
                for row in db.execute("SELECT digest,ext FROM images WHERE state='ready'").fetchall():
                    original = library.root / "originals" / f"{row['digest']}.{row['ext']}"
                    if not original.is_file() or checksum(original) != row["digest"]:
                        raise ValueError("An original is missing or corrupt; recover it from a verified backup")
                    library._publish(db, row["digest"], row["ext"])
                    count += 1
        return count


def restore_backup(source, destination):
    source = source.resolve()
    destination = destination.resolve()
    if destination.is_relative_to(source) or source.is_relative_to(destination):
        raise ValueError("Restore destination must be separate from the backup")
    destination, staging = staging_for(destination)
    try:
        with TemporaryDirectory() as temporary:
            manifest_path = Path(temporary) / "manifest.json"
            unprotect(source / "manifest.protected", manifest_path)
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            if manifest["format"] != 1:
                raise ValueError("Unsupported backup version")
            seen = set()
            for entry in manifest["files"]:
                relative = PurePosixPath(entry["path"])
                blob = entry["blob"]
                if (relative.is_absolute() or ".." in relative.parts or ":" in str(relative)
                        or "\\" in str(relative) or entry["path"] in seen
                        or Path(blob).name != blob or not blob.endswith(".protected")):
                    raise ValueError("Unsafe backup entry")
                seen.add(entry["path"])
                target = staging.joinpath(*relative.parts)
                if not target.resolve().is_relative_to(staging.resolve()):
                    raise ValueError("Restore entry escapes staging")
                target.parent.mkdir(parents=True, exist_ok=True)
                unprotect(source / blob, target)
                if target.stat().st_size != entry["size"] or checksum(target) != entry["sha256"]:
                    raise ValueError("Backup checksum mismatch")
            for relative in ("data/metadata.sqlite", "data/device_tokens.sqlite", "generated/generated.sqlite"):
                path = staging / relative
                if not path.exists():
                    continue
                with closing(sqlite3.connect(path)) as db, db:
                    if db.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                        raise ValueError("Restored database integrity check failed")
                    tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                    if "sync_meta" in tables:
                        db.execute("UPDATE sync_meta SET epoch=?", (str(uuid.uuid4()),))
                    if "generation_jobs" in tables:
                        db.execute("""UPDATE generation_jobs SET state='failed',error='復元後はComfyUIの実行状態を確認してください'
                            WHERE state NOT IN ('completed','failed','cancelled')""")
                    if "device_tokens" in tables:
                        db.execute("UPDATE device_tokens SET revoked=COALESCE(revoked,?)", (time.time(),))
            settings = manifest["settings"]
            mappings = [(Path(root), destination / "media" / str(index)) for index, root in enumerate(settings["media_roots"])]
            metadata = staging / "data" / "metadata.sqlite"
            if metadata.exists():
                with closing(sqlite3.connect(metadata)) as db, db:
                    for table, columns in (("media_records", ("full_path", "normalized_full_path", "folder_raw")),
                                           ("indexed_folders", ("folder_raw",))):
                        for column in columns:
                            for old, new in mappings:
                                rows = db.execute(f"SELECT rowid,{column} FROM {table}").fetchall()
                                for rowid, value in rows:
                                    path = Path(value)
                                    if path.is_relative_to(old):
                                        replacement = str(new / path.relative_to(old))
                                        if column == "normalized_full_path":
                                            replacement = os.path.normcase(replacement)
                                        db.execute(f"UPDATE {table} SET {column}=? WHERE rowid=?", (replacement, rowid))
            (staging / "output").mkdir(exist_ok=True)
            for _, root in mappings:
                staging.joinpath(*root.relative_to(destination).parts).mkdir(parents=True, exist_ok=True)
            safe = {"MEDIA_SERVER_DATA_DIR": str(destination / "data"),
                    "MEDIA_SERVER_DB_PATH": str(destination / "data" / "metadata.sqlite"),
                    "MEDIA_SERVER_THUMBS_DIR": str(destination / "thumbs"),
                    "MEDIA_SERVER_MEDIA_ROOTS": ";".join(str(new) for _, new in mappings),
                    "MEDIA_SERVER_XVIEWER_SAVED_IMAGES_DIR": str(destination / "saved-images"),
                    "MEDIA_SERVER_HOST": "127.0.0.1", "MEDIA_SERVER_PORT": str(settings["port"])}
            if settings.get("generated_library_dir"):
                safe.update(MEDIA_SERVER_GENERATED_LIBRARY_DIR=str(destination / "generated"),
                            MEDIA_SERVER_COMFY_OUTPUT_DIR=str(destination / "output"))
            # Generation stays opt-in after restore. Review the stored presets before enabling.
            (staging / "restored_settings.json").write_text(json.dumps(safe, indent=2), encoding="utf-8")
            staging.rename(destination)
        return len(manifest["files"])
    finally:
        discard_staging(staging, destination)
