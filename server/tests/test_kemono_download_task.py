import os
import tempfile
import unittest
from pathlib import Path

from PIL import Image

from server.kemono_download_task import _convert_gallery_to_pdf


class KemonoDownloadTaskTest(unittest.TestCase):
    def test_convert_gallery_to_pdf_removes_source_gallery_images(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            artist_dir = Path(temp_dir) / "hitomi" / "[12345] ArtistName"
            gallery_dir = artist_dir / "[20241105] [3114110] Sample Title"
            gallery_dir.mkdir(parents=True, exist_ok=True)

            image_path = gallery_dir / "001.png"
            Image.new("RGB", (32, 48), color="red").save(image_path)

            converted = _convert_gallery_to_pdf(gallery_dir)

            self.assertTrue(converted)
            self.assertTrue((artist_dir / "Sample Title.pdf").exists())
            self.assertFalse(gallery_dir.exists())

    def test_convert_gallery_to_pdf_cleans_up_source_gallery_when_pdf_is_current(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            artist_dir = Path(temp_dir) / "hitomi" / "[12345] ArtistName"
            gallery_dir = artist_dir / "[20241105] [3114110] Sample Title"
            gallery_dir.mkdir(parents=True, exist_ok=True)

            pdf_path = artist_dir / "Sample Title.pdf"
            pdf_path.parent.mkdir(parents=True, exist_ok=True)
            pdf_path.write_bytes(b"%PDF-1.4")

            image_path = gallery_dir / "001.png"
            Image.new("RGB", (32, 48), color="blue").save(image_path)

            future_mtime = pdf_path.stat().st_mtime + 60
            os.utime(pdf_path, (future_mtime, future_mtime))

            converted = _convert_gallery_to_pdf(gallery_dir)

            self.assertFalse(converted)
            self.assertTrue(pdf_path.exists())
            self.assertFalse(gallery_dir.exists())


if __name__ == "__main__":
    unittest.main()
