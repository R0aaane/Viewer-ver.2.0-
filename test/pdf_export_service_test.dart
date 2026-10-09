import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:pdf_viewer/database/pdf_export_service.dart';
import 'package:pdf_viewer/models/mediaItem.dart';
import 'package:pdf_viewer/repository/mediaRepository.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

class _ImageRepository extends Fake implements MediaRepository {
  _ImageRepository(this.bytes);
  final Uint8List bytes;

  @override
  Future<Uint8List> readPdfSourceBytes(
    MediaItem item, {
    int maxWidth = 2800,
  }) async => bytes;
}

void main() {
  const item = MediaItem(
    id: 'source.png',
    displayName: 'source.png',
    kind: MediaKind.image,
    folderRaw: '',
  );

  test(
    'conversion fails instead of silently dropping an unreadable image',
    () async {
      await expectLater(
        PdfExportService.buildPdfBytes(_ImageRepository(Uint8List(128)), [
          item,
        ]).timeout(const Duration(seconds: 5)),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'cause',
            contains('decoded'),
          ),
        ),
      );
    },
  );

  test('valid images still produce one PDF page per source', () async {
    final png = Uint8List.fromList(im.encodePng(im.Image(width: 2, height: 3)));
    final bytes = await PdfExportService.buildPdfBytes(_ImageRepository(png), [
      item,
      item,
    ]);
    final document = sf.PdfDocument(inputBytes: bytes);
    try {
      expect(document.pages.count, 2);
    } finally {
      document.dispose();
    }
  });
}
