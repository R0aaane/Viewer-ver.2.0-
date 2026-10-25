import 'dart:typed_data';

abstract interface class PdfPageEditorClient {
  Future<Map<String, dynamic>> fetchPdfEditInfo(String mediaId);
  Future<Map<String, dynamic>> savePdfPages(
    String mediaId,
    String revision,
    List<Map<String, int>> pages,
  );
  Future<Map<String, dynamic>> restorePdfBackup(
    String mediaId,
    String revision,
    String backupId,
  );
  Future<Uint8List> fetchThumbnail(
    String mediaId, {
    int? width,
    int? height,
    int? page,
    bool refresh = false,
  });
}
