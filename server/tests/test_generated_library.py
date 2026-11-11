import hashlib
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

from PIL import Image, PngImagePlugin

from server.services.generated_library import GeneratedLibrary


class GeneratedLibraryTests(unittest.TestCase):
    def test_thumbnail_keeps_palette_transparency_pixels(self):
        path = self.source / "palette.png"
        image = Image.new("P", (40, 20))
        image.putpalette([255, 0, 0, 0, 255, 0] + [0] * (768 - 6))
        image.paste(1, (20, 0, 40, 20))
        image.info["transparency"] = bytes([0, 160] + [255] * 254)
        image.save(path)
        self.tick()
        self.tick()
        with self.library.connect() as db:
            digest = db.execute("SELECT digest FROM images WHERE state='ready'").fetchone()[0]
        with Image.open(self.library.media_path(digest, True)) as thumbnail:
            self.assertEqual(thumbnail.convert("RGBA").tobytes(), image.convert("RGBA").tobytes())

    def test_derived_metadata_and_ready_state_roll_back_together(self):
        from server.services import generated_catalog
        self.image()
        self.tick()
        original_analyze = generated_catalog.analyze
        def fail_after_analysis(*args, **kwargs):
            original_analyze(*args, **kwargs)
            raise OSError("interrupted metadata publication")
        with patch.object(generated_catalog, "analyze", side_effect=fail_after_analysis):
            with self.assertRaises(OSError):
                self.tick()
        with self.library.connect() as db:
            self.assertEqual(db.execute("SELECT state FROM images").fetchone()[0], "staged")
            self.assertEqual(db.execute("SELECT COUNT(*) FROM generation_info").fetchone()[0], 0)
        self.tick()
        with self.library.connect() as db:
            self.assertEqual(db.execute("SELECT state FROM images").fetchone()[0], "ready")
            self.assertEqual(db.execute("SELECT COUNT(*) FROM generation_info").fetchone()[0], 1)
    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.base = Path(temp.name)
        self.source = self.base / "output"
        self.source.mkdir()
        self.root = self.base / "generated"
        self.library = GeneratedLibrary(self.source, self.root)
        self.now = 1_000_000_000
        clock = patch("server.services.generated_library.time.time_ns", side_effect=lambda: self.now)
        clock.start()
        self.addCleanup(clock.stop)

    def image(self, name="001.png"):
        path = self.source / name
        meta = PngImagePlugin.PngInfo()
        meta.add_text("workflow", '{"nodes":[]}')
        Image.new("RGB", (640, 320), "red").save(path, pnginfo=meta)
        return path

    def tick(self):
        self.now += 5_000_000_000
        self.library.scan()

    def test_duplicate_contents_are_published_once_with_original_metadata(self):
        path = self.image()
        payload = path.read_bytes()
        nested = self.source / "sub"
        nested.mkdir()
        (nested / "copy.PNG").write_bytes(payload)
        self.library.scan()
        self.library.scan()
        self.assertEqual(self.library.events(0, 10), [])
        self.tick()
        self.tick()
        digest = hashlib.sha256(payload).hexdigest()
        self.assertEqual(self.library.events(0, 10), [{"seq": 1, "mediaId": digest}])
        self.assertEqual(self.library.events(1, 10), [])
        self.assertEqual(self.library.media_path(digest, False).read_bytes(), payload)
        self.assertEqual(path.read_bytes(), payload)
        with Image.open(self.library.media_path(digest, True)) as thumb:
            self.assertEqual(thumb.size, (384, 192))

    def test_incomplete_and_changed_files_are_retried_without_touching_source(self):
        path = self.source / "writing.png"
        path.write_bytes(b"partial")
        self.library.scan()
        with self.assertLogs("server.services.generated_library", level="WARNING"):
            self.tick()
        self.assertEqual(self.library.events(0, 5), [])
        self.assertEqual(path.read_bytes(), b"partial")
        self.image(path.name)
        self.tick()
        self.assertEqual(self.library.events(0, 5), [])
        self.tick()
        self.assertEqual(len(self.library.events(0, 5)), 1)

    def test_restart_after_staging_atomic_placement_or_thumbnail(self):
        for boundary in ("original", "thumbnail", "event"):
            with self.subTest(boundary=boundary):
                path = self.source / (boundary + ".png")
                Image.new("RGB", (20, 20), {"original": "red", "thumbnail": "green",
                                            "event": "blue"}[boundary]).save(path)
                self.tick()
                replace = Path.replace

                def interrupt(src, dst):
                    if boundary == "original" and src.name == "incoming.part":
                        raise OSError("interrupted")
                    if boundary == "thumbnail" and src.name == "thumb.part":
                        raise OSError("interrupted")
                    result = replace(src, dst)
                    if boundary == "event" and src.name == "thumb.part":
                        raise OSError("interrupted")
                    return result

                digest = hashlib.sha256(path.read_bytes()).hexdigest()
                with patch.object(Path, "replace", interrupt), self.assertRaises(OSError):
                    self.tick()
                self.assertIsNone(self.library.media_path(digest, False))
                path.unlink()  # Staged bytes alone must be sufficient to repair.
                self.library = GeneratedLibrary(self.source, self.root)
                self.tick()
                self.assertTrue(self.library.media_path(digest, False).exists())
                self.assertTrue(self.library.media_path(digest, True).exists())
                ids = [row["mediaId"] for row in self.library.events(0, 10)]
                self.assertEqual(ids.count(digest), 1)

    def test_copy_mismatch_is_not_registered(self):
        self.image()
        self.tick()
        real_open = Path.open

        def damage_copy(path, mode="r", *args, **kwargs):
            if path.name == "incoming.part" and mode == "rb":
                with real_open(path, "r+b") as out:
                    out.write(b"bad")
            return real_open(path, mode, *args, **kwargs)

        with patch.object(Path, "open", damage_copy), self.assertLogs(level="WARNING"):
            self.tick()
        self.assertEqual(self.library.events(0, 10), [])
        self.tick()
        self.assertEqual(len(self.library.events(0, 10)), 1)

    def test_process_exit_after_journaling_releases_lock_and_resumes(self):
        path = self.image()
        self.library.scan()
        # The child's real clock makes the parent's synthetic observation old
        # enough to copy. os._exit bypasses all Python cleanup handlers.
        child = """
import os, sys
from pathlib import Path
from server.services.generated_library import GeneratedLibrary
worker = GeneratedLibrary(Path(sys.argv[1]), Path(sys.argv[2]))
worker._publish = lambda *args: os._exit(23)
worker.scan()
"""
        result = subprocess.run([sys.executable, "-c", child, str(self.source), str(self.root)],
                                timeout=20, check=False)
        self.assertEqual(result.returncode, 23)
        path.unlink()
        self.library = GeneratedLibrary(self.source, self.root)
        self.tick()
        self.assertEqual(len(self.library.events(0, 10)), 1)

    def test_damaged_staging_after_restart_is_recopied_from_source(self):
        path = self.image()
        expected = path.read_bytes()
        self.library.scan()
        with patch.object(Path, "replace", side_effect=OSError("disk full")), self.assertRaises(OSError):
            self.tick()
        (self.root / "incoming.part").write_bytes(b"damaged")
        self.library = GeneratedLibrary(self.source, self.root)
        with self.assertLogs(level="WARNING"):
            self.tick()
        digest = hashlib.sha256(expected).hexdigest()
        self.assertEqual(self.library.media_path(digest, False).read_bytes(), expected)
        self.assertEqual(self.library.events(0, 5), [{"seq": 1, "mediaId": digest}])

    def test_worker_lock_blocks_second_process_writer(self):
        self.image()
        self.tick()
        with self.library._worker_lock() as acquired:
            self.assertTrue(acquired)
            GeneratedLibrary(self.source, self.root).scan()
        self.assertEqual(self.library.events(0, 10), [])
        self.tick()
        self.assertEqual(len(self.library.events(0, 10)), 1)

    def test_overlapping_and_nonempty_destinations_are_rejected(self):
        for root in (self.source, self.source / "nested", self.base):
            with self.assertRaises(ValueError):
                GeneratedLibrary(self.source, root)
        existing = self.base / "existing"
        existing.mkdir()
        (existing / "user-file").touch()
        with self.assertRaises(ValueError):
            GeneratedLibrary(self.source, existing)
        with self.assertRaises(ValueError):
            GeneratedLibrary(self.source, self.base / "public" / "private", [self.base / "public"])
