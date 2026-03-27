import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/mediaItem.dart';

class ResolvedMediaIdentity {
  final String stableId;
  final List<String> aliases;
  final int? sizeBytes;
  final int? modifiedEpochMs;
  final String normalizedPath;
  final String relativePathHint;

  const ResolvedMediaIdentity({
    required this.stableId,
    required this.aliases,
    required this.sizeBytes,
    required this.modifiedEpochMs,
    required this.normalizedPath,
    required this.relativePathHint,
  });

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'mediaId': stableId,
      'aliases': aliases,
      'normalizedPath': normalizedPath,
      'relativePathHint': relativePathHint,
      'sizeBytes': sizeBytes,
      'modifiedEpochMs': modifiedEpochMs,
    };
  }
}

class MediaIdResolver {
  final Map<String, Future<ResolvedMediaIdentity>> _cache =
      <String, Future<ResolvedMediaIdentity>>{};

  Future<ResolvedMediaIdentity> resolve(MediaItem item) {
    final cacheKey =
        '${item.id}|${item.modified?.millisecondsSinceEpoch ?? 0}|${item.sizeBytes ?? -1}';
    final cached = _cache[cacheKey];
    if (cached != null) {
      return cached;
    }

    final future = _resolveInternal(item);
    _cache[cacheKey] = future;
    return future;
  }

  void forget(MediaItem item) {
    final cacheKey =
        '${item.id}|${item.modified?.millisecondsSinceEpoch ?? 0}|${item.sizeBytes ?? -1}';
    _cache.remove(cacheKey);
  }

  Future<ResolvedMediaIdentity> _resolveInternal(MediaItem item) async {
    final normalizedPath = normalizeLocator(item.id);
    final normalizedFolder = normalizeLocator(item.folderRaw);
    final relativePathHint = _relativePathHint(item, normalizedPath, normalizedFolder);

    int? sizeBytes = item.sizeBytes;
    final modifiedEpochMs = item.modified?.millisecondsSinceEpoch;

    if (sizeBytes == null && !_isContentUri(item.id) && item.kind != MediaKind.folder) {
      try {
        final stat = await File(item.id).stat();
        sizeBytes = stat.size;
      } catch (_) {
        sizeBytes = null;
      }
    }

    final source = <String>[
      'v1',
      item.kind.name,
      normalizedPath,
      normalizedFolder,
      relativePathHint,
      (sizeBytes ?? -1).toString(),
      (modifiedEpochMs ?? -1).toString(),
    ].join('|');

    final aliases = <String>{
      item.id,
      normalizedPath,
      item.id.replaceAll('\\', '/'),
      item.id.replaceAll('/', '\\'),
      item.id.toLowerCase(),
      normalizedPath.toLowerCase(),
    }.toList(growable: false);

    return ResolvedMediaIdentity(
      stableId: 'mid_${_fnv1a64Hex(source)}',
      aliases: aliases,
      sizeBytes: sizeBytes,
      modifiedEpochMs: modifiedEpochMs,
      normalizedPath: normalizedPath,
      relativePathHint: relativePathHint,
    );
  }

  String normalizeLocator(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return trimmed;
    }

    if (_isContentUri(trimmed)) {
      return trimmed;
    }

    final normalized = p.normalize(trimmed).replaceAll('/', '\\');
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  String _relativePathHint(
    MediaItem item,
    String normalizedPath,
    String normalizedFolder,
  ) {
    if (_isContentUri(item.id)) {
      return item.displayName;
    }

    if (normalizedFolder.isNotEmpty && normalizedPath.startsWith(normalizedFolder)) {
      final prefixLength = normalizedFolder.length;
      if (normalizedPath.length > prefixLength) {
        return normalizedPath.substring(prefixLength).replaceFirst(RegExp(r'^[\\/]+'), '');
      }
    }
    return item.displayName;
  }

  bool _isContentUri(String raw) => raw.startsWith('content://');

  String _fnv1a64Hex(String input) {
    const int offset = 0xcbf29ce484222325;
    const int prime = 0x100000001b3;

    var hash = offset;
    for (final unit in input.codeUnits) {
      hash ^= unit;
      hash = (hash * prime) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}
