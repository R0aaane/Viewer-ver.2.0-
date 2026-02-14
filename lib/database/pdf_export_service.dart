import 'dart:io';
import 'dart:typed_data';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf/pdf.dart';
import 'package:path_provider/path_provider.dart';

import '../models/mediaItem.dart';
import '../repository/mediaRepository.dart';

class PdfExportService {
  static Future<File> exportFolderToPdf(
    MediaRepository repo,
    List<MediaItem> items,
    String fileName,
  ) async {
    final pdf = pw.Document();

    for (final item in items) {
      if (item.kind != MediaKind.image) continue;

      final bytes = await repo.readBytes(item);

      final image = pw.MemoryImage(bytes);

      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          build: (context) {
            return pw.Center(
              child: pw.Image(image, fit: pw.BoxFit.contain),
            );
          },
        ),
      );
    }

    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$fileName.pdf');

    await file.writeAsBytes(await pdf.save());

    return file;
  }
}
