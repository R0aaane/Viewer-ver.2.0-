import tempfile
import unittest
from pathlib import Path

from PIL import Image

from server.repositories.sqlite_store import SqliteStore
from server.api.routes_actions import (
    _flatten_imported_media_paths,
    _prefer_gif_collection_import_paths,
)
from server.services.media_index_service import MediaIndexService
from server.services.metadata_store import MetadataStore
from server.services.thumbnail_service import ThumbnailService


_GIF_1X1 = (
    b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff!"
    b"\xf9\x04\x00\x00\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00"
    b"\x00\x02\x02D\x01\x00;"
)


def _write_animated_webp(path: Path) -> bool:
    try:
        first = Image.new("RGBA", (1, 1), (255, 0, 0, 255))
        second = Image.new("RGBA", (1, 1), (0, 0, 255, 255))
        first.save(
            path,
            format="WEBP",
            save_all=True,
            append_images=[second],
            duration=[100, 100],
            loop=0,
        )
        return True
    except Exception:
        return False


class GifCollectionTest(unittest.TestCase):
    def setUp(self) -> None:
        self._temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._temp_dir.cleanup)

        root = Path(self._temp_dir.name)
        self.library_dir = root / "library"
        self.library_dir.mkdir()
        self.thumbs_dir = root / "thumbs"

        self.sqlite = SqliteStore(root / "metadata.db")
        self.addCleanup(self.sqlite.close)
        self.sqlite.init_schema()
        self.metadata = MetadataStore(self.sqlite)
        self.index = MediaIndexService(self.sqlite)
        self.thumbnails = ThumbnailService(self.metadata, self.thumbs_dir)

    def test_gif_folder_indexes_as_pdf_like_collection(self) -> None:
        collection = self.library_dir / "[20240101] [123] Sample GIF"
        collection.mkdir()
        (collection / "002.gif").write_bytes(_GIF_1X1)
        (collection / "001.gif").write_bytes(_GIF_1X1)

        self.index.scan_folder(str(self.library_dir))
        records = self.sqlite.list_media_records(include_deleted=False)

        self.assertEqual(len(records), 1)
        record = records[0]
        self.assertEqual(record["kind"], "pdf")
        self.assertEqual(record["mime_type"], "application/x.gif-collection")
        self.assertEqual(Path(record["full_path"]), collection)
        self.assertEqual(
            self.thumbnails.get_pdf_page_count(str(record["media_id"])),
            2,
        )
        rendered = self.thumbnails.render_pdf_page(
            str(record["media_id"]),
            page_no=1,
        )
        self.assertEqual(rendered.mime, "image/gif")
        self.assertTrue(rendered.payload.startswith(b"GIF"))

    def test_index_files_collapses_gif_members_into_collection(self) -> None:
        collection = self.library_dir / "Sample GIF"
        collection.mkdir()
        first = collection / "001.gif"
        second = collection / "002.gif"
        first.write_bytes(_GIF_1X1)
        second.write_bytes(_GIF_1X1)

        self.index.index_files([str(first), str(second)])
        records = self.sqlite.list_media_records(include_deleted=False)

        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["kind"], "pdf")
        self.assertEqual(records[0]["mime_type"], "application/x.gif-collection")
        self.assertEqual(Path(records[0]["full_path"]), collection)

    def test_index_files_keeps_single_gif_as_image_file(self) -> None:
        gif_file = self.library_dir / "animated.gif"
        gif_file.write_bytes(_GIF_1X1)

        self.index.index_files([str(gif_file)])
        records = self.sqlite.list_media_records(include_deleted=False)

        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["kind"], "image")
        self.assertEqual(records[0]["mime_type"], "image/gif")
        self.assertEqual(Path(records[0]["full_path"]), gif_file)

    def test_animated_webp_folder_indexes_as_gif_collection(self) -> None:
        collection = self.library_dir / "Sample Animated WebP"
        collection.mkdir()
        if not _write_animated_webp(collection / "001.webp"):
            self.skipTest("Pillow WebP animation support is unavailable")
        (collection / "002.webp").write_bytes(b"not animated webp")

        self.index.scan_folder(str(self.library_dir))
        records = self.sqlite.list_media_records(include_deleted=False)

        self.assertEqual(len(records), 2)
        collection_record = next(
            record
            for record in records
            if record["mime_type"] == "application/x.gif-collection"
        )
        self.assertEqual(collection_record["kind"], "pdf")
        self.assertEqual(
            self.thumbnails.get_pdf_page_count(str(collection_record["media_id"])),
            1,
        )
        rendered = self.thumbnails.render_pdf_page(
            str(collection_record["media_id"]),
            page_no=1,
        )
        self.assertEqual(rendered.mime, "image/webp")
        self.assertTrue(rendered.payload.startswith(b"RIFF"))

    def test_delete_gif_collection_removes_directory(self) -> None:
        collection = self.library_dir / "Sample GIF"
        collection.mkdir()
        (collection / "001.gif").write_bytes(_GIF_1X1)
        self.index.scan_folder(str(self.library_dir))
        record = self.sqlite.list_media_records(include_deleted=False)[0]

        deleted = self.metadata.apply_delete(
            [{"mediaId": str(record["media_id"])}],
            hard_delete=True,
        )

        self.assertEqual(deleted, 1)
        self.assertFalse(collection.exists())

    def test_single_hitomi_gif_imports_as_file(self) -> None:
        staging = Path(self._temp_dir.name) / "stage"
        gallery = staging / "hitomi" / "artist" / "[20240101] [123] Sample GIF"
        gallery.mkdir(parents=True)
        (gallery / "001.gif").write_bytes(_GIF_1X1)

        paths = _prefer_gif_collection_import_paths(
            str(staging),
            [str(gallery / "001.gif")],
        )

        self.assertEqual(paths, [str(gallery / "001.gif")])

    def test_flattened_gif_collection_uses_stripped_hitomi_title(self) -> None:
        staging = Path(self._temp_dir.name) / "stage"
        gallery = staging / "hitomi" / "artist" / "[20240101] [123] Sample GIF"
        gallery.mkdir(parents=True)
        (gallery / "001.gif").write_bytes(_GIF_1X1)
        (gallery / "002.gif").write_bytes(_GIF_1X1)

        entries = _flatten_imported_media_paths(str(staging), [str(gallery)])

        self.assertEqual(len(entries), 1)
        self.assertEqual(Path(entries[0][0]).name, "Sample GIF")
        self.assertEqual(entries[0][1], "hitomi/artist/Sample GIF")


if __name__ == "__main__":
    unittest.main()
