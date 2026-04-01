import '../models/mediaItem.dart';

class ItemNameValidationException implements Exception {
  final String message;

  const ItemNameValidationException(this.message);

  @override
  String toString() => message;
}

class ItemNameService {
  static final RegExp _invalidChars = RegExp(r'[\\/:*?"<>|]');

  static String editableBaseName(MediaItem item) {
    if (item.kind == MediaKind.folder) {
      return item.displayName;
    }

    final dot = item.displayName.lastIndexOf('.');
    if (dot <= 0 || dot == item.displayName.length - 1) {
      return item.displayName;
    }
    return item.displayName.substring(0, dot);
  }

  static String kindLabel(MediaItem item) {
    switch (item.kind) {
      case MediaKind.pdf:
        return 'PDF';
      case MediaKind.image:
        return '画像';
      case MediaKind.folder:
        return 'フォルダ';
    }
  }

  static String? validateEditableName(String rawName) {
    if (rawName.isEmpty) {
      return '新しい名前を入力してください';
    }
    if (rawName != rawName.trim()) {
      return '先頭または末尾の空白は使えません';
    }
    if (rawName == '.' || rawName == '..') {
      return 'その名前は使用できません';
    }
    if (_invalidChars.hasMatch(rawName)) {
      return r'\/:*?"<>| は使えません';
    }
    if (rawName.endsWith(' ') || rawName.endsWith('.')) {
      return '末尾のスペースまたはピリオドは使えません';
    }
    return null;
  }

  static String buildDisplayName(MediaItem item, String rawName) {
    final trimmed = rawName.trim();
    final error = validateEditableName(trimmed);
    if (error != null) {
      throw ItemNameValidationException(error);
    }

    if (item.kind == MediaKind.folder) {
      return trimmed;
    }

    final currentExt = _extensionOf(item.displayName);
    if (currentExt.isEmpty) {
      return trimmed;
    }

    if (trimmed.toLowerCase().endsWith(currentExt.toLowerCase())) {
      final base = trimmed.substring(0, trimmed.length - currentExt.length);
      final baseError = validateEditableName(base);
      if (baseError != null) {
        throw ItemNameValidationException(baseError);
      }
      return trimmed;
    }

    return '$trimmed$currentExt';
  }

  static String _extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) {
      return '';
    }
    return name.substring(dot);
  }
}
