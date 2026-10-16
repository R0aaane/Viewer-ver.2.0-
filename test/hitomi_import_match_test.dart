import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/web/hitomi_import_match.dart';
import 'package:pdf_viewer/repository/mediaRepository.dart';

void main() {
  bool matches(String name, {String path = '', String title = '作品'}) =>
      matchesImportedHitomi(
        galleryId: 12345,
        title: title,
        displayName: name,
        path: path,
      );

  test('matches gallery IDs in filenames and original paths', () {
    expect(matches('作品 [12345].pdf'), isTrue);
    expect(matches('001.jpg', path: r'C:\hitomi\12345\001.jpg'), isTrue);
    expect(matches('other_123456.pdf'), isFalse);
  });

  test(
    'matches normalized titles without treating empty titles as imported',
    () {
      expect(matches('作品.pdf'), isTrue);
      expect(matches('My_Work.pdf', title: 'my-work'), isTrue);
      expect(matches('別作品.pdf'), isFalse);
      expect(matches('', title: ''), isFalse);
    },
  );

  test('bulk import passes every selected gallery URL', () {
    const urls = [
      'https://hitomi.la/galleries/12345.html',
      'https://hitomi.la/galleries/67890.html',
    ];
    expect(
      const UrlImportOptions(
        convertHitomiToPdf: true,
      ).collectSourceUrls(urls.join('\n')),
      urls,
    );
  });
}
