import 'package:path/path.dart' as p;

/// Match the same gallery IDs and normalized titles as the native search UI.
bool matchesImportedHitomi({
  required int galleryId,
  required String title,
  required String displayName,
  required String path,
}) {
  final idPattern = RegExp('(^|[^0-9])$galleryId([^0-9]|\$)');
  if (idPattern.hasMatch(displayName) || idPattern.hasMatch(path)) return true;
  String normalize(String value) => p
      .basenameWithoutExtension(value)
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[\s_\-]+'), ' ');
  final key = normalize(title);
  return key.isNotEmpty && normalize(displayName) == key;
}
