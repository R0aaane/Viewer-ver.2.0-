import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/repository/mediaRepository.dart';

void main() {
  group('UrlImportOptions.suggestedUiState', () {
    test('uses hitomi defaults for hitomi urls', () {
      final suggested = const UrlImportOptions().suggestedUiState(
        'https://hitomi.la/reader/123456.html',
      );

      expect(suggested.siteKemono, isFalse);
      expect(suggested.siteCoomer, isFalse);
      expect(suggested.convertHitomiToPdf, isTrue);
    });

    test('uses kemono defaults for kemono urls', () {
      final suggested = const UrlImportOptions().suggestedUiState(
        'https://kemono.su/fanbox/user/12345/post/67890',
      );

      expect(suggested.siteKemono, isTrue);
      expect(suggested.siteCoomer, isFalse);
      expect(suggested.convertHitomiToPdf, isFalse);
    });

    test('uses coomer defaults for coomer urls', () {
      final suggested = const UrlImportOptions().suggestedUiState(
        'https://coomer.su/onlyfans/user/example',
      );

      expect(suggested.siteKemono, isFalse);
      expect(suggested.siteCoomer, isTrue);
      expect(suggested.convertHitomiToPdf, isFalse);
    });

    test('preserves generic defaults when no source is detected', () {
      final suggested = const UrlImportOptions().suggestedUiState('');

      expect(suggested.siteKemono, isTrue);
      expect(suggested.siteCoomer, isFalse);
      expect(suggested.convertHitomiToPdf, isTrue);
    });
  });
}
