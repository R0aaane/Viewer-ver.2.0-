import 'package:path/path.dart' as p;

import '../models/tag.dart';

class InferredImportTags {
  final String relativePathHint;
  final List<Tag> tags;

  const InferredImportTags({
    required this.relativePathHint,
    required this.tags,
  });
}

class ImportTagRuleService {
  static final p.Context _windowsPath = p.Context(style: p.Style.windows);
  static final p.Context _posixPath = p.Context(style: p.Style.posix);

  static const Map<String, String> _siteTags = <String, String>{
    'hitomi': 'hitomi',
    'kemono': 'kemono',
  };

  static const Set<String> _serviceSegments = <String>{
    'hitomi',
    'kemono',
    'coomer',
    'patreon',
    'fanbox',
    'fantia',
    'gumroad',
    'subscribestar',
    'subscribestarad',
    'dlsite',
    'onlyfans',
    'fansly',
    'discord',
    'afdian',
    'boosty',
    'candfans',
    'pixiv',
  };

  static const Set<String> _genericSegments = <String>{
    'download',
    'downloads',
    'library',
    'images',
    'image',
    'files',
    'file',
    'posts',
    'post',
    'gallery',
    'galleries',
    'books',
    'book',
    'archives',
    'archive',
    'pdf',
    'pdfs',
    '\u4f5c\u8005\u5225',
    '\u30b7\u30ea\u30fc\u30ba',
  };

  static final RegExp _bracketedDigits = RegExp(r'\[\s*\d+\s*\]');
  static final RegExp _whitespace = RegExp(r'\s+');
  static final RegExp _digitsOnly = RegExp(r'^\d+$');
  static final RegExp _windowsDrive = RegExp(r'^[a-zA-Z]:$');

  static InferredImportTags inferForGeneratedPdf({
    required String sourceFolderRaw,
    required String sourceFolderLabel,
    required String generatedFileName,
    String? libraryRootRaw,
    List<String> sourceUrls = const <String>[],
  }) {
    final relativePathHint = _buildRelativePathHint(
      sourceFolderRaw: sourceFolderRaw,
      sourceFolderLabel: sourceFolderLabel,
      generatedFileName: generatedFileName,
      libraryRootRaw: libraryRootRaw,
    );
    return InferredImportTags(
      relativePathHint: relativePathHint,
      tags: inferFromRelativePath(
        relativePathHint: relativePathHint,
        sourceUrls: sourceUrls,
      ),
    );
  }

  static InferredImportTags inferForImportedItem({
    required String itemPath,
    required String rootFolderRaw,
    String? displayName,
    List<String> sourceUrls = const <String>[],
  }) {
    final relativePathHint = _buildRelativePathHintForImportedItem(
      itemPath: itemPath,
      rootFolderRaw: rootFolderRaw,
      displayName: displayName,
    );
    return InferredImportTags(
      relativePathHint: relativePathHint,
      tags: inferFromRelativePath(
        relativePathHint: relativePathHint,
        sourceUrls: sourceUrls,
      ),
    );
  }

  static List<Tag> inferFromRelativePath({
    String? relativePathHint,
    List<String> sourceUrls = const <String>[],
  }) {
    final segments = _relativeDirectoryParts(relativePathHint);
    final loweredSegments = segments
        .map((segment) => segment.toLowerCase())
        .toList(growable: false);
    final loweredUrls = sourceUrls
        .map((url) => url.trim().toLowerCase())
        .where((url) => url.isNotEmpty)
        .toList(growable: false);

    final out = <Tag>[];
    final artistTag = _inferArtistTagFromParts(segments);
    if (artistTag != null) {
      out.add(Tag(name: artistTag, category: TagCategory.artist));
    }

    final mediaTypeTags = <String>{};
    for (final entry in _siteTags.entries) {
      if (loweredSegments.any((segment) => segment.contains(entry.key)) ||
          loweredUrls.any((url) => url.contains(entry.key))) {
        mediaTypeTags.add(entry.value);
      }
    }
    final isHitomiContext = mediaTypeTags.contains('hitomi');
    final seriesTag = _inferSeriesTagFromParts(
      segments,
      relativePathHint: relativePathHint,
      isHitomiContext: isHitomiContext,
      artistTag: artistTag,
    );
    if (seriesTag != null) {
      out.add(Tag(name: seriesTag, category: TagCategory.series));
    }
    final sortedMediaTypeTags = mediaTypeTags.toList(growable: false)..sort();
    for (final name in sortedMediaTypeTags) {
      out.add(Tag(name: name, category: TagCategory.mediaType));
    }
    return out;
  }

  static bool isWithinLibrary({
    required String itemPath,
    required String libraryRoot,
  }) {
    if (itemPath.trim().isEmpty ||
        libraryRoot.trim().isEmpty ||
        itemPath.startsWith('content://') ||
        libraryRoot.startsWith('content://')) {
      return false;
    }
    final ctx = _pathContextFor(itemPath, libraryRoot);
    final normalizedItem = ctx.normalize(itemPath);
    final normalizedRoot = ctx.normalize(libraryRoot);
    return normalizedItem == normalizedRoot ||
        ctx.isWithin(normalizedRoot, normalizedItem);
  }

  static String _buildRelativePathHint({
    required String sourceFolderRaw,
    required String sourceFolderLabel,
    required String generatedFileName,
    String? libraryRootRaw,
  }) {
    final normalizedFileName = generatedFileName.trim().isEmpty
        ? 'generated.pdf'
        : generatedFileName.trim();
    final rawFolder = sourceFolderRaw.trim();
    final rawLibraryRoot = libraryRootRaw?.trim() ?? '';

    if (rawFolder.isNotEmpty &&
        !rawFolder.startsWith('content://') &&
        rawLibraryRoot.isNotEmpty &&
        !rawLibraryRoot.startsWith('content://') &&
        isWithinLibrary(itemPath: rawFolder, libraryRoot: rawLibraryRoot)) {
      final ctx = _pathContextFor(rawFolder, rawLibraryRoot);
      final relativeFolder = ctx.relative(
        ctx.normalize(rawFolder),
        from: ctx.normalize(rawLibraryRoot),
      );
      final cleanedRelativeFolder = relativeFolder == '.'
          ? ''
          : relativeFolder.replaceAll('\\', '/');
      if (cleanedRelativeFolder.isEmpty) {
        return normalizedFileName;
      }
      return '$cleanedRelativeFolder/$normalizedFileName';
    }

    final folderSegments = rawFolder.isEmpty || rawFolder.startsWith('content://')
        ? const <String>[]
        : _pathTailSegments(rawFolder);
    final effectiveSegments = folderSegments.isEmpty &&
            sourceFolderLabel.trim().isNotEmpty
        ? <String>[sourceFolderLabel.trim()]
        : folderSegments;
    if (effectiveSegments.isEmpty) {
      return normalizedFileName;
    }
    return [...effectiveSegments, normalizedFileName].join('/');
  }

  static List<String> _pathTailSegments(String rawPath) {
    final normalized = rawPath.replaceAll('\\', '/');
    final parts = normalized
        .split('/')
        .map((segment) => segment.trim())
        .where((segment) => segment.isNotEmpty && !_windowsDrive.hasMatch(segment))
        .toList(growable: false);
    if (parts.length <= 4) {
      return parts;
    }
    return parts.sublist(parts.length - 4);
  }

  static String _buildRelativePathHintForImportedItem({
    required String itemPath,
    required String rootFolderRaw,
    String? displayName,
  }) {
    final rawItemPath = itemPath.trim();
    final rawRoot = rootFolderRaw.trim();
    final fallbackName = (displayName?.trim().isNotEmpty ?? false)
        ? displayName!.trim()
        : p.basename(rawItemPath);

    if (rawItemPath.isNotEmpty &&
        rawRoot.isNotEmpty &&
        !rawItemPath.startsWith('content://') &&
        !rawRoot.startsWith('content://') &&
        isWithinLibrary(itemPath: rawItemPath, libraryRoot: rawRoot)) {
      final ctx = _pathContextFor(rawItemPath, rawRoot);
      return ctx
          .relative(
            ctx.normalize(rawItemPath),
            from: ctx.normalize(rawRoot),
          )
          .replaceAll('\\', '/');
    }

    final tailSegments = rawItemPath.isEmpty || rawItemPath.startsWith('content://')
        ? const <String>[]
        : _pathTailSegments(rawItemPath);
    if (tailSegments.isEmpty) {
      return fallbackName;
    }
    return tailSegments.join('/');
  }

  static List<String> _relativeDirectoryParts(String? relativePathHint) {
    final raw = (relativePathHint ?? '').trim();
    if (raw.isEmpty) {
      return const <String>[];
    }
    final parts = raw
        .split(RegExp(r'[\\/]+'))
        .map((segment) => segment.trim())
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (parts.length <= 1) {
      return const <String>[];
    }
    return parts.sublist(0, parts.length - 1);
  }

  static String? _inferArtistTagFromParts(List<String> parts) {
    if (parts.isEmpty) {
      return null;
    }

    final serviceIndexes = <int>[];
    for (var i = 0; i < parts.length; i++) {
      if (_isServiceSegment(parts[i])) {
        serviceIndexes.add(i);
      }
    }

    final startIndex = serviceIndexes.isEmpty ? 0 : serviceIndexes.last + 1;
    for (var i = startIndex; i < parts.length; i++) {
      final candidate = _cleanArtistTagCandidate(parts[i]);
      if (candidate != null) {
        return candidate;
      }
    }

    for (final part in parts) {
      final candidate = _cleanArtistTagCandidate(part);
      if (candidate != null) {
        return candidate;
      }
    }
    return null;
  }

  static String? _inferSeriesTagFromParts(
    List<String> parts, {
    required String? relativePathHint,
    required bool isHitomiContext,
    String? artistTag,
  }) {
    if (!isHitomiContext) {
      return null;
    }

    final serviceIndexes = <int>[];
    for (var i = 0; i < parts.length; i++) {
      if (_isServiceSegment(parts[i])) {
        serviceIndexes.add(i);
      }
    }

    final startIndex = serviceIndexes.isEmpty ? 0 : serviceIndexes.last + 1;
    for (var i = startIndex + 1; i < parts.length; i++) {
      final candidate = _cleanSeriesTagCandidate(parts[i], artistTag: artistTag);
      if (candidate != null) {
        return candidate;
      }
    }

    final fileStem = _relativeFileStem(relativePathHint);
    return _cleanSeriesTagCandidate(fileStem, artistTag: artistTag);
  }

  static String? _cleanArtistTagCandidate(String segment) {
    var cleaned = segment.trim();
    cleaned = cleaned.replaceAll(_bracketedDigits, ' ');
    cleaned = cleaned.replaceAll(_whitespace, ' ').trim();
    cleaned = cleaned.replaceAll(RegExp(r'^[-_\[\]\(\)\{\}\s]+'), '');
    cleaned = cleaned.replaceAll(RegExp(r'[-_\[\]\(\)\{\}\s]+$'), '');
    if (cleaned.isEmpty) {
      return null;
    }

    final lowered = cleaned.toLowerCase();
    if (_serviceSegments.contains(lowered) || _genericSegments.contains(lowered)) {
      return null;
    }
    if (_digitsOnly.hasMatch(cleaned)) {
      return null;
    }
    return cleaned;
  }

  static String? _cleanSeriesTagCandidate(
    String? segment, {
    String? artistTag,
  }) {
    if (segment == null) {
      return null;
    }

    final cleaned = _cleanArtistTagCandidate(segment);
    if (cleaned == null) {
      return null;
    }

    final loweredArtist = artistTag?.trim().toLowerCase();
    if (loweredArtist != null && loweredArtist.isNotEmpty) {
      if (cleaned.toLowerCase() == loweredArtist) {
        return null;
      }
    }
    return cleaned;
  }

  static String? _relativeFileStem(String? relativePathHint) {
    final raw = (relativePathHint ?? '').trim();
    if (raw.isEmpty) {
      return null;
    }

    final parts = raw
        .split(RegExp(r'[\\/]+'))
        .map((segment) => segment.trim())
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (parts.isEmpty) {
      return null;
    }

    final fileName = parts.last;
    final dot = fileName.lastIndexOf('.');
    if (dot <= 0) {
      return fileName;
    }
    return fileName.substring(0, dot);
  }

  static bool _isServiceSegment(String segment) {
    final lowered = segment.trim().toLowerCase();
    if (lowered.isEmpty) {
      return false;
    }
    if (_serviceSegments.contains(lowered)) {
      return true;
    }
    for (final token in _siteTags.keys) {
      if (lowered.contains(token)) {
        return true;
      }
    }
    return false;
  }

  static p.Context _pathContextFor(String first, String second) {
    final looksWindowsPath =
        first.contains('\\') ||
        second.contains('\\') ||
        _looksLikeWindowsPrefix(first) ||
        _looksLikeWindowsPrefix(second);
    return looksWindowsPath ? _windowsPath : _posixPath;
  }

  static bool _looksLikeWindowsPrefix(String raw) {
    final parts = raw.split(RegExp(r'[\\/]+'));
    if (parts.isEmpty) {
      return false;
    }
    return _windowsDrive.hasMatch(parts.first.trim());
  }
}
