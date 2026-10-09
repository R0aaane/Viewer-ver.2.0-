import unittest
from types import SimpleNamespace

from fastapi import HTTPException

from server.services.media_stream_service import MediaStreamService


class MediaStreamRangeTest(unittest.TestCase):
    def setUp(self):
        self.service = MediaStreamService(None, SimpleNamespace(stream_chunk_size=4))

    def test_valid_ranges(self):
        for header, expected in [
            ("bytes=0-3", (0, 3)),
            ("bytes=3-", (3, 9)),
            ("bytes=-3", (7, 9)),
            ("bytes=-30", (0, 9)),
            ("bytes=2-99", (2, 9)),
        ]:
            with self.subTest(header=header):
                self.assertEqual(self.service._parse_range(header, 10), expected)

    def test_malformed_ranges_return_client_errors(self):
        for header in [
            "bytes=abc-def", "bytes=1", "bytes=-", "bytes=1--2",
            "bytes=+1-2", "bytes=1-2,4-5", "bytes=-0", "bytes=5-2",
        ]:
            with self.subTest(header=header):
                with self.assertRaises(HTTPException) as raised:
                    self.service._parse_range(header, 10)
                self.assertEqual(raised.exception.status_code, 400)

    def test_unsatisfiable_ranges_include_the_file_size(self):
        for header, size in [("bytes=10-", 10), ("bytes=0-", 0), ("bytes=-3", 0)]:
            with self.subTest(header=header, size=size):
                with self.assertRaises(HTTPException) as raised:
                    self.service._parse_range(header, size)
                self.assertEqual(raised.exception.status_code, 416)
                self.assertEqual(raised.exception.headers, {"Content-Range": f"bytes */{size}"})
