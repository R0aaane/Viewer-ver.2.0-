"""Crash-recoverable, opt-in importer for a host-managed ComfyUI output tree."""
from __future__ import annotations

import hashlib
import logging
import os
import shutil
import sqlite3
import stat
import struct
import threading
import time
import warnings
from contextlib import closing, contextmanager
from pathlib import Path

from PIL import Image, ImageOps
from server.services import generated_catalog

logger = logging.getLogger(__name__)
FORMATS = {"PNG": "png", "JPEG": "jpg", "WEBP": "webp"}
EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp"}
BLOCK = 1024 * 1024


def _signature(info):
    return f"{info.st_dev}:{info.st_ino}:{info.st_size}:{info.st_mtime_ns}:{info.st_ctime_ns}"


def _is_link(info):
    return stat.S_ISLNK(info.st_mode) or bool(
        getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT
    )


def _file_digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        while data := stream.read(BLOCK):
            checksum.update(data)
    return checksum.hexdigest()


class GeneratedLibrary:
    def __init__(self, source: Path, root: Path, protected_roots=()):
        self.source = source.resolve()
        self.root = root.resolve()
        if not self.source.is_dir():
            raise ValueError("ComfyUI output must be an existing directory")
        for other in (self.source, *(Path(path).resolve() for path in protected_roots)):
            if self.root.is_relative_to(other) or other.is_relative_to(self.root):
                raise ValueError("Generated library must be separate from source and existing roots")
        self.db_path = self.root / "generated.sqlite"
        self.root.mkdir(parents=True, exist_ok=True)
        if not self.db_path.exists() and any(self.root.iterdir()):
            raise ValueError("Use a new or empty generated-library directory")
        with closing(self.connect()) as db:
            app_id = db.execute("PRAGMA application_id").fetchone()[0]
            if app_id != 0x47504C31:
                if app_id or db.execute("SELECT 1 FROM sqlite_master LIMIT 1").fetchone():
                    raise ValueError("Unrecognized generated-library database")
                db.execute("PRAGMA application_id=0x47504C31")
            db.execute("PRAGMA journal_mode=WAL")
            db.executescript("""
                CREATE TABLE IF NOT EXISTS sources (
                    path TEXT PRIMARY KEY, signature TEXT NOT NULL, observed_ns INTEGER NOT NULL,
                    done INTEGER NOT NULL, digest TEXT
                );
                CREATE TABLE IF NOT EXISTS images (
                    digest TEXT PRIMARY KEY, ext TEXT NOT NULL, state TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS images_by_state ON images(state);
                CREATE TABLE IF NOT EXISTS events (
                    seq INTEGER PRIMARY KEY, digest TEXT NOT NULL UNIQUE
                );
            """)
            generated_catalog.initialize(db)
        for name in ("originals", "thumbs"):
            (self.root / name).mkdir(exist_ok=True)
        self.stop = threading.Event()
        self._backfill_after = ""
        self.thread = threading.Thread(target=self._run, name="generated-import", daemon=True)

    def connect(self):
        db = sqlite3.connect(self.db_path, timeout=5)
        db.row_factory = sqlite3.Row
        return db

    def start(self):
        self.thread.start()

    def import_download(self, path: Path):
        """Publish a host-downloaded image using the existing recovery journal."""
        with self._worker_lock() as acquired:
            if not acquired:
                return None
            with closing(self.connect()) as db:
                # scan() owns recovery of any previously interrupted publication.
                if db.execute("SELECT 1 FROM images WHERE state <> 'ready'").fetchone():
                    return None
                try:
                    with warnings.catch_warnings():
                        warnings.simplefilter("error", Image.DecompressionBombWarning)
                        with Image.open(path, formats=list(FORMATS)) as image:
                            ext = FORMATS[image.format]
                            image.verify()
                        with Image.open(path) as image:
                            for frame in range(getattr(image, "n_frames", 1)):
                                image.seek(frame)
                                image.load()
                except (OSError, SyntaxError, ValueError, EOFError, struct.error,
                        Image.DecompressionBombError, Image.DecompressionBombWarning) as exc:
                    if isinstance(exc, OSError) and exc.errno is not None:
                        raise
                    raise ValueError("ComfyUIの出力画像を読み取れません") from exc
                digest = _file_digest(path)
                if db.execute("SELECT 1 FROM images WHERE digest=? AND state='ready'", (digest,)).fetchone():
                    return digest
                with path.open("rb") as src, (self.root / "incoming.part").open("wb") as dst:
                    shutil.copyfileobj(src, dst, BLOCK)
                    dst.flush()
                    os.fsync(dst.fileno())
                with db:
                    db.execute("INSERT INTO images VALUES (?, ?, 'staged')", (digest, ext))
                self._publish(db, digest, ext)
                return digest

    def close(self):
        self.stop.set()
        self.thread.join()

    def _run(self):
        while not self.stop.is_set():
            try:
                self.scan()
            except Exception:
                logger.exception("Generated library scan failed; will retry")
            self.stop.wait(5)

    @contextmanager
    def _worker_lock(self):
        # A separate SQLite lock serializes filesystem publication across host
        # processes. Readers of the catalog continue during large copies.
        with closing(sqlite3.connect(self.root / "worker.sqlite", timeout=0)) as lock:
            try:
                lock.execute("BEGIN IMMEDIATE")
            except sqlite3.OperationalError as exc:
                if "locked" not in str(exc).lower():
                    raise
                yield False
            else:
                try:
                    yield True
                finally:
                    lock.rollback()

    def scan(self):
        with self._worker_lock() as acquired:
            if not acquired:
                return
            with closing(self.connect()) as db:
                # At most one staged image owns incoming.part. Finish it before
                # allowing another copy, even if the original source disappeared.
                for row in db.execute("SELECT * FROM images WHERE state <> 'ready'"):
                    original = self.root / "originals" / f"{row['digest']}.{row['ext']}"
                    staged = self.root / "incoming.part"
                    if not original.exists() and (not staged.is_file() or _file_digest(staged) != row["digest"]):
                        with db:
                            db.execute("UPDATE sources SET done=0, digest=NULL WHERE digest=?", (row["digest"],))
                            db.execute("DELETE FROM images WHERE digest=?", (row["digest"],))
                        logger.warning("Incomplete staging file; retrying from ComfyUI output")
                        continue
                    self._publish(db, row["digest"], row["ext"])
                # Index existing Phase 2 originals in bounded batches.
                missing = db.execute("""SELECT i.digest,i.ext FROM images i LEFT JOIN generation_info g
                    ON i.digest=g.digest WHERE i.state='ready' AND g.digest IS NULL AND i.digest>?
                    ORDER BY i.digest LIMIT 64""", (self._backfill_after,)).fetchall()
                self._backfill_after = missing[-1]["digest"] if len(missing) == 64 else ""
                for row in missing:
                    if self.stop.is_set():
                        return
                    original = self.root / "originals" / f"{row['digest']}.{row['ext']}"
                    try:
                        if original.is_file():
                            generated_catalog.analyze(db, row["digest"], original)
                    except (ValueError, OSError, SyntaxError):
                        logger.warning("Cannot read metadata for %s", row["digest"], exc_info=True)
                observations = []
                for directory, children, files in os.walk(self.source):
                    if self.stop.is_set():
                        return
                    parent = Path(directory)
                    children[:] = [n for n in children if not _is_link((parent / n).lstat())]
                    for name in files:
                        if self.stop.is_set():
                            return
                        path = parent / name
                        if path.suffix.lower() not in EXTENSIONS:
                            continue
                        try:
                            observation = self._consider(db, path)
                            if observation is not None:
                                observations.append(observation)
                                if len(observations) >= 500:
                                    self._record_observations(db, observations)
                        except (OSError, ValueError, SyntaxError, Image.DecompressionBombError,
                                Image.DecompressionBombWarning):
                            # Once a copy is journaled the scratch file belongs
                            # to it. Stop this pass and recover before reusing it.
                            if db.execute("SELECT 1 FROM images WHERE state <> 'ready'").fetchone():
                                raise
                            logger.warning("Generated image deferred: %s", path.name, exc_info=True)
                self._record_observations(db, observations)

    @staticmethod
    def _record_observations(db, observations):
        if observations:
            with db:
                db.executemany("INSERT OR REPLACE INTO sources VALUES (?, ?, ?, 0, NULL)", observations)
            observations.clear()

    def _consider(self, db, path):
        info = path.lstat()
        if _is_link(info) or not stat.S_ISREG(info.st_mode):
            return
        signature = _signature(info)
        key = str(path.relative_to(self.source))
        row = db.execute("SELECT * FROM sources WHERE path=?", (key,)).fetchone()
        if row is not None and row["signature"] == signature and row["done"]:
            return
        # Unchanged, already imported files require no content access. Resolve
        # containment whenever a file will be observed or opened.
        if not path.resolve().is_relative_to(self.source):
            return
        if row is None or row["signature"] != signature:
            return key, signature, time.time_ns()
        if row["done"] or time.time_ns() - row["observed_ns"] < 2_000_000_000:
            return

        scratch = self.root / "incoming.part"
        digest = hashlib.sha256()
        with path.open("rb") as src, scratch.open("wb") as dst:
            if _signature(os.fstat(src.fileno())) != signature:
                return
            while data := src.read(BLOCK):
                if self.stop.is_set():
                    return
                dst.write(data)
                digest.update(data)
            dst.flush()
            os.fsync(dst.fileno())
        if _signature(path.lstat()) != signature or scratch.stat().st_size != info.st_size:
            return
        media_id = _file_digest(scratch)
        if media_id != digest.hexdigest():
            raise OSError("Copy checksum mismatch")
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("error", Image.DecompressionBombWarning)
                with Image.open(scratch, formats=list(FORMATS)) as image:
                    ext = FORMATS[image.format]
                    image.verify()
                with Image.open(scratch) as image:
                    for frame in range(getattr(image, "n_frames", 1)):
                        image.seek(frame)
                        image.load()
        except (OSError, SyntaxError, ValueError, EOFError, struct.error,
                Image.DecompressionBombError, Image.DecompressionBombWarning) as exc:
            if isinstance(exc, OSError) and exc.errno is not None:
                raise
            # Retry invalid images only after a new signature is observed.
            with db:
                db.execute("UPDATE sources SET done=2 WHERE path=?", (key,))
            scratch.unlink(missing_ok=True)
            logger.warning("Ignoring incomplete or unsupported image until modified: %s", path.name)
            return
        with db:
            inserted = db.execute("INSERT OR IGNORE INTO images VALUES (?, ?, 'staged')",
                                  (media_id, ext)).rowcount
            db.execute("UPDATE sources SET done=1, digest=? WHERE path=?", (media_id, key))
        if inserted:
            self._publish(db, media_id, ext)
        else:
            scratch.unlink(missing_ok=True)

    def _publish(self, db, digest, ext):
        original = self.root / "originals" / f"{digest}.{ext}"
        if not original.exists():
            (self.root / "incoming.part").replace(original)
        thumb = self.root / "thumbs" / f"{digest}.png"
        if not thumb.exists():
            temporary = self.root / "thumb.part"
            with Image.open(original) as image:
                image.thumbnail((384, 384))
                preview = ImageOps.exif_transpose(image)
                if preview.mode not in ("1", "L", "LA", "P", "RGB", "RGBA"):
                    preview = preview.convert("RGBA")
                with temporary.open("wb") as out:
                    preview.save(out, format="PNG", compress_level=1)
                    out.flush()
                    os.fsync(out.fileno())
            temporary.replace(thumb)
        with db:
            # A staged row plus an atomically published original is sufficient
            # for crash recovery. Publish derived metadata and readiness together.
            generated_catalog.analyze(db, digest, original, commit=False)
            db.execute("UPDATE images SET state='ready' WHERE digest=?", (digest,))
            db.execute("INSERT OR IGNORE INTO events(digest) VALUES (?)", (digest,))

    def events(self, after, limit):
        with closing(self.connect()) as db:
            return [dict(row) for row in db.execute(
                "SELECT seq, digest AS mediaId FROM events WHERE seq>? ORDER BY seq LIMIT ?",
                (after, limit),
            )]

    def media_path(self, digest, thumbnail):
        with closing(self.connect()) as db:
            row = db.execute("SELECT ext FROM images WHERE digest=? AND state='ready'",
                             (digest,)).fetchone()
        if row is None:
            return None
        if thumbnail:
            return self.root / "thumbs" / f"{digest}.png"
        return self.root / "originals" / f"{digest}.{row['ext']}"
