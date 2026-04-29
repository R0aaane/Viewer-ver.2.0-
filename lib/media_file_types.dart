class MediaFileTypes {
  // Keep this list aligned with server/core/media_formats.py.
  static const List<String> imagePickerExtensions = <String>[
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'bmp',
    'avif',
  ];

  static const List<String> mediaPickerExtensions = <String>[
    ...imagePickerExtensions,
    'pdf',
  ];

  static const Set<String> imageExtensions = <String>{
    '.jpg',
    '.jpeg',
    '.png',
    '.gif',
    '.webp',
    '.bmp',
    '.avif',
  };

  static const Set<String> mediaExtensions = <String>{
    ...imageExtensions,
    '.pdf',
  };

  static String extensionOf(String fileName) {
    final trimmed = fileName.trim();
    final dot = trimmed.lastIndexOf('.');
    if (dot < 0 || dot == trimmed.length - 1) {
      return '';
    }
    return trimmed.substring(dot).toLowerCase();
  }

  static bool isSupportedImageFileName(String fileName) {
    return imageExtensions.contains(extensionOf(fileName));
  }

  static bool isSupportedMediaFileName(String fileName) {
    return mediaExtensions.contains(extensionOf(fileName));
  }

  static String imageMimeTypeForFileName(String fileName) {
    switch (extensionOf(fileName)) {
      case '.png':
        return 'image/png';
      case '.gif':
        return 'image/gif';
      case '.webp':
        return 'image/webp';
      case '.bmp':
        return 'image/bmp';
      case '.avif':
        return 'image/avif';
      default:
        return 'image/jpeg';
    }
  }
}
