import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/media_file_types.dart';

void main() {
  group('MediaFileTypes', () {
    test('treats bmp as a supported image format', () {
      expect(MediaFileTypes.isSupportedImageFileName('cover.BMP'), isTrue);
      expect(MediaFileTypes.isSupportedMediaFileName('cover.BMP'), isTrue);
      expect(MediaFileTypes.imageMimeTypeForFileName('cover.bmp'), 'image/bmp');
    });

    test('rejects unsupported media extensions', () {
      expect(MediaFileTypes.isSupportedImageFileName('cover.gif'), isFalse);
      expect(MediaFileTypes.isSupportedMediaFileName('cover.gif'), isFalse);
      expect(MediaFileTypes.isSupportedMediaFileName('book.pdf'), isTrue);
    });
  });
}
