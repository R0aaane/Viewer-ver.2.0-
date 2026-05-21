import 'dart:typed_data';

class DownloadedImage {
  const DownloadedImage({
    required this.bytes,
    required this.fileName,
    required this.mimeType,
    required this.sourceUrl,
  });

  final Uint8List bytes;
  final String fileName;
  final String mimeType;
  final String sourceUrl;
}
