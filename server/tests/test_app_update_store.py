import asyncio
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

from server.core.errors import ApiError
from server.services.app_update_store import load_app_update_info, save_app_update_upload


class _FakeUpload:
    def __init__(self, filename: str, data: bytes) -> None:
        self.filename = filename
        self._data = data
        self._offset = 0

    async def read(self, size: int = -1) -> bytes:
        if self._offset >= len(self._data):
            return b""
        if size < 0:
            size = len(self._data) - self._offset
        chunk = self._data[self._offset : self._offset + size]
        self._offset += len(chunk)
        return chunk


class AppUpdateStoreTest(unittest.TestCase):
    def test_save_and_load_uploaded_update(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            settings = SimpleNamespace(data_dir=Path(temp_dir))

            info = asyncio.run(
                save_app_update_upload(
                    settings,
                    version="1.0.2+3",
                    upload=_FakeUpload("pdf_viewer.apk", b"apk-data"),
                )
            )
            loaded = load_app_update_info(settings)

            self.assertEqual(info.version, "1.0.2+3")
            self.assertEqual(loaded, info)
            self.assertTrue((settings.data_dir / "app_updates" / info.file_name).is_file())

    def test_rejects_unsupported_file_type(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            settings = SimpleNamespace(data_dir=Path(temp_dir))

            with self.assertRaises(ApiError):
                asyncio.run(
                    save_app_update_upload(
                        settings,
                        version="1.0.2+3",
                        upload=_FakeUpload("notes.txt", b"data"),
                    )
                )


if __name__ == "__main__":
    unittest.main()
