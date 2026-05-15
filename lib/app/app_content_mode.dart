enum AppContentMode { r18, reader }

class AppContentModeConfig {
  static const String _raw = String.fromEnvironment(
    'PDF_VIEWER_CONTENT_MODE',
    defaultValue: 'r18',
  );

  static const AppContentMode current = _raw == 'reader'
      ? AppContentMode.reader
      : AppContentMode.r18;

  static bool get isReader => current == AppContentMode.reader;
  static bool get isR18 => current == AppContentMode.r18;
}
