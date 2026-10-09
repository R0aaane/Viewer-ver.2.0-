import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock

from server.services.thumbnail_service import ThumbnailService


class ThumbnailShutdownTest(unittest.TestCase):
    def test_shutdown_closes_all_documents_even_if_one_close_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            service = ThumbnailService(Mock(), Path(directory))
            first, second = Mock(), Mock()
            first.close.side_effect = RuntimeError("close failed")
            service._pdf_cache.update({"first.pdf": first, "second.pdf": second})
            with self.assertLogs("server.services.thumbnail_service", level="WARNING"):
                service.close()
            service.close()
            first.close.assert_called_once()
            second.close.assert_called_once()
            self.assertFalse(service._pdf_cache)
