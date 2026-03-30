import 'dart:convert';

enum ImportInputKind {
  path,
  fileUri,
  contentUri,
  jsonArrayString,
  jsonString,
}

class NormalizedImportInput {
  final String originalValue;
  final String normalizedValue;
  final ImportInputKind kind;

  const NormalizedImportInput({
    required this.originalValue,
    required this.normalizedValue,
    required this.kind,
  });

  bool get isContentUri => normalizedValue.startsWith('content://');
}

class ImportSourceNormalizer {
  const ImportSourceNormalizer._();

  static List<NormalizedImportInput> normalizeRawInputs(
    Iterable<String> rawItems,
  ) {
    final out = <NormalizedImportInput>[];
    final seen = <String>{};
    for (final raw in rawItems) {
      for (final entry in _expandRawValue(raw)) {
        final key = entry.normalizedValue.trim();
        if (key.isEmpty || !seen.add(key)) {
          continue;
        }
        out.add(entry);
      }
    }
    return out;
  }

  static String? normalizeSingleValue(String raw) {
    final normalized = normalizeRawInputs(<String>[raw]);
    if (normalized.isEmpty) {
      return null;
    }
    return normalized.first.normalizedValue;
  }

  static bool looksLikeEncodedCollection(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    if (!(trimmed.startsWith('[') || trimmed.startsWith('"'))) {
      return false;
    }
    final decoded = _tryDecodeJson(trimmed);
    return decoded is List || decoded is String;
  }

  static String basenameFromPathish(String raw) {
    final normalized = normalizeSingleValue(raw)?.trim() ?? raw.trim();
    if (normalized.isEmpty) {
      return '';
    }
    final flattened = normalized.replaceAll('\\', '/');
    final slash = flattened.lastIndexOf('/');
    if (slash >= 0 && slash + 1 < flattened.length) {
      return flattened.substring(slash + 1).trim();
    }
    return normalized;
  }

  static List<NormalizedImportInput> _expandRawValue(
    String raw, {
    ImportInputKind? decodedKind,
  }) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return const <NormalizedImportInput>[];
    }

    final decoded = _tryDecodeJson(trimmed);
    if (decoded is List) {
      final expanded = decoded
          .whereType<String>()
          .expand(
            (entry) => _expandRawValue(
              entry,
              decodedKind: ImportInputKind.jsonArrayString,
            ),
          )
          .toList(growable: false);
      if (expanded.isNotEmpty) {
        return expanded;
      }
    } else if (decoded is String) {
      final normalizedDecoded = decoded.trim();
      if (normalizedDecoded.isNotEmpty && normalizedDecoded != trimmed) {
        return _expandRawValue(
          normalizedDecoded,
          decodedKind: ImportInputKind.jsonString,
        );
      }
    }

    final normalizedValue = _normalizeUriLikeValue(trimmed);
    return <NormalizedImportInput>[
      NormalizedImportInput(
        originalValue: raw,
        normalizedValue: normalizedValue,
        kind: decodedKind ?? _kindForValue(normalizedValue),
      ),
    ];
  }

  static dynamic _tryDecodeJson(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  static String _normalizeUriLikeValue(String raw) {
    if (!raw.startsWith('file://')) {
      return raw;
    }
    try {
      return Uri.parse(raw).toFilePath();
    } catch (_) {
      return raw;
    }
  }

  static ImportInputKind _kindForValue(String value) {
    if (value.startsWith('content://')) {
      return ImportInputKind.contentUri;
    }
    if (value.startsWith('file://')) {
      return ImportInputKind.fileUri;
    }
    return ImportInputKind.path;
  }
}
