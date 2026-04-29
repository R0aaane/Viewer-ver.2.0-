import unittest

from server.core.media_formats import (
    SUPPORTED_IMAGE_EXTENSIONS,
    SUPPORTED_MEDIA_EXTENSIONS,
    is_supported_media_extension,
    media_kind_for_extension,
    normalized_extension,
)


class MediaFormatsTest(unittest.TestCase):
    def test_bmp_is_supported_across_server_helpers(self) -> None:
        self.assertIn('.bmp', SUPPORTED_IMAGE_EXTENSIONS)
        self.assertIn('.bmp', SUPPORTED_MEDIA_EXTENSIONS)
        self.assertTrue(is_supported_media_extension(normalized_extension('cover.BMP')))
        self.assertEqual(media_kind_for_extension('.bmp'), 'image')

    def test_avif_is_supported_across_server_helpers(self) -> None:
        self.assertIn('.avif', SUPPORTED_IMAGE_EXTENSIONS)
        self.assertIn('.avif', SUPPORTED_MEDIA_EXTENSIONS)
        self.assertTrue(is_supported_media_extension(normalized_extension('cover.AVIF')))
        self.assertEqual(media_kind_for_extension('.avif'), 'image')

    def test_gif_is_supported_across_server_helpers(self) -> None:
        self.assertIn('.gif', SUPPORTED_IMAGE_EXTENSIONS)
        self.assertIn('.gif', SUPPORTED_MEDIA_EXTENSIONS)
        self.assertTrue(is_supported_media_extension(normalized_extension('cover.GIF')))
        self.assertEqual(media_kind_for_extension('.gif'), 'image')

    def test_unknown_extension_is_rejected(self) -> None:
        self.assertFalse(is_supported_media_extension('.tga'))
        self.assertIsNone(media_kind_for_extension('.tga'))


if __name__ == '__main__':
    unittest.main()
