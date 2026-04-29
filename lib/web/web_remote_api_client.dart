// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:pdfx/pdfx.dart';

import '../repository/mediaRepository.dart';
import '../models/tag.dart';
import '../models/reading_progress.dart';

const String _pdfJsScriptId = 'pdfjs-runtime-loader';
const String _pdfJsLibraryUrl =
    'https://unpkg.com/pdfjs-dist@3.11.174/legacy/build/pdf.min.js';
const String _pdfJsWorkerUrl =
    'https://unpkg.com/pdfjs-dist@3.11.174/legacy/build/pdf.worker.min.js';

Future<void>? _pdfJsLoadFuture;

@JS('pdfjsLib')
external _PdfJsLib? get _pdfJsLib;

extension type _PdfJsLib(JSObject _) implements JSObject {
  @JS('getDocument')
  external JSAny? get getDocumentMethod;

  @JS('GlobalWorkerOptions')
  external _PdfJsGlobalWorkerOptions? get globalWorkerOptions;
}

extension type _PdfJsGlobalWorkerOptions(JSObject _) implements JSObject {
  external String? get workerSrc;
  external set workerSrc(String? value);
}

_PdfJsLib? _pdfJsLibObject() => _pdfJsLib;

bool _pdfJsHasGetDocument(_PdfJsLib? lib) => lib?.getDocumentMethod != null;

void _configurePdfJsWorkerSource(_PdfJsLib? lib) {
  final options = lib?.globalWorkerOptions;
  if (options == null) {
    return;
  }

  final currentText = options.workerSrc?.trim() ?? '';
  if (currentText.isEmpty) {
    options.workerSrc = _pdfJsWorkerUrl;
  }
}

Future<void> _ensurePdfJsReady() async {
  final existing = _pdfJsLibObject();
  if (_pdfJsHasGetDocument(existing)) {
    _configurePdfJsWorkerSource(existing);
    return;
  }

  final inFlight = _pdfJsLoadFuture;
  if (inFlight != null) {
    await inFlight;
    return;
  }

  final future = _loadPdfJsScript();
  _pdfJsLoadFuture = future;
  try {
    await future;
  } catch (_) {
    _pdfJsLoadFuture = null;
    rethrow;
  }
}

Future<void> _loadPdfJsScript() async {
  final alreadyLoaded = _pdfJsLibObject();
  if (_pdfJsHasGetDocument(alreadyLoaded)) {
    _configurePdfJsWorkerSource(alreadyLoaded);
    return;
  }

  final completer = Completer<void>();
  StreamSubscription<html.Event>? loadSubscription;
  StreamSubscription<html.Event>? errorSubscription;

  void finishSuccessfully() {
    if (completer.isCompleted) {
      return;
    }
    final lib = _pdfJsLibObject();
    if (!_pdfJsHasGetDocument(lib)) {
      completer.completeError(
        const WebRemoteException('PDF.js は読み込まれましたが初期化に失敗しました'),
      );
      return;
    }
    _configurePdfJsWorkerSource(lib);
    completer.complete();
  }

  void finishWithError(Object error) {
    if (completer.isCompleted) {
      return;
    }
    completer.completeError(error);
  }

  try {
    final existingElement = html.document.getElementById(_pdfJsScriptId);
    final script =
        existingElement is html.ScriptElement
              ? existingElement
              : html.ScriptElement()
          ..id = _pdfJsScriptId
          ..async = true
          ..defer = true
          ..crossOrigin = 'anonymous'
          ..src = _pdfJsLibraryUrl;

    loadSubscription = script.onLoad.listen((_) {
      finishSuccessfully();
    });
    errorSubscription = script.onError.listen((_) {
      finishWithError(const WebRemoteException('PDF.js の読み込みに失敗しました'));
    });

    if (existingElement == null) {
      final root = html.document.head ?? html.document.body;
      if (root == null) {
        finishWithError(
          const WebRemoteException('PDF.js を追加する DOM を取得できませんでした'),
        );
      } else {
        root.append(script);
      }
    }

    // If another part of the page finished loading PDF.js before the listeners
    // were attached, complete immediately.
    if (_pdfJsHasGetDocument(_pdfJsLibObject())) {
      finishSuccessfully();
    }

    await completer.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () =>
          throw const WebRemoteException('PDF.js の読み込みがタイムアウトしました'),
    );
  } finally {
    await loadSubscription?.cancel();
    await errorSubscription?.cancel();
  }
}

class WebRemoteException implements Exception {
  final String message;
  final int? statusCode;

  const WebRemoteException(this.message, {this.statusCode});

  @override
  String toString() => message;
}

class WebRemoteFolder {
  final String raw;
  final String displayName;
  final DateTime? lastScannedAt;

  const WebRemoteFolder({
    required this.raw,
    required this.displayName,
    this.lastScannedAt,
  });
}

class WebRemoteMediaStats {
  final DateTime addedAt;
  final DateTime? lastViewedAt;
  final int viewCount;

  const WebRemoteMediaStats({
    required this.addedAt,
    required this.lastViewedAt,
    required this.viewCount,
  });
}

class WebRemoteMediaActivityEntry {
  final String mediaId;
  final String folderRaw;
  final DateTime viewedAt;
  final int? lastPage;

  const WebRemoteMediaActivityEntry({
    required this.mediaId,
    required this.folderRaw,
    required this.viewedAt,
    required this.lastPage,
  });
}

class WebRemoteEntry {
  final String entryId;
  final String displayName;
  final String folderRaw;
  final String kind;
  final String? mediaId;
  final String? fullPath;
  final int? sizeBytes;
  final DateTime? modifiedAt;
  final WebRemoteMediaStats? stats;

  const WebRemoteEntry({
    required this.entryId,
    required this.displayName,
    required this.folderRaw,
    required this.kind,
    required this.mediaId,
    required this.fullPath,
    required this.sizeBytes,
    required this.modifiedAt,
    required this.stats,
  });

  bool get isFolder => kind == 'folder';
  bool get isPdf => kind == 'pdf';
  bool get isImage => kind == 'image';

  String get stableId => mediaId ?? fullPath ?? entryId;

  WebRemoteEntry copyWith({
    String? entryId,
    String? displayName,
    String? folderRaw,
    String? kind,
    String? mediaId,
    String? fullPath,
    int? sizeBytes,
    DateTime? modifiedAt,
    WebRemoteMediaStats? stats,
  }) {
    return WebRemoteEntry(
      entryId: entryId ?? this.entryId,
      displayName: displayName ?? this.displayName,
      folderRaw: folderRaw ?? this.folderRaw,
      kind: kind ?? this.kind,
      mediaId: mediaId ?? this.mediaId,
      fullPath: fullPath ?? this.fullPath,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      modifiedAt: modifiedAt ?? this.modifiedAt,
      stats: stats ?? this.stats,
    );
  }
}

class WebRemoteMediaMeta {
  final String mediaId;
  final String displayName;
  final String kind;
  final String? mimeType;
  final int? sizeBytes;
  final DateTime? modifiedAt;
  final String? etag;
  final bool supportsRange;
  final int? pageCount;
  final WebRemoteMediaStats? stats;

  const WebRemoteMediaMeta({
    required this.mediaId,
    required this.displayName,
    required this.kind,
    required this.mimeType,
    required this.sizeBytes,
    required this.modifiedAt,
    required this.etag,
    required this.supportsRange,
    required this.pageCount,
    required this.stats,
  });
}

class WebRemotePdfPageCountInfo {
  final int count;
  final bool isReliable;

  const WebRemotePdfPageCountInfo({
    required this.count,
    required this.isReliable,
  });
}

class WebRemoteOrganizeResult {
  final Map<String, String> moved;
  final int movedCount;
  final int rescannedCount;

  const WebRemoteOrganizeResult({
    required this.moved,
    required this.movedCount,
    required this.rescannedCount,
  });
}

class WebRemoteUrlImportResult {
  final int importedCount;
  final int skippedCount;
  final int failedCount;
  final int taggedCount;
  final int organizedCount;
  final int rescannedCount;
  final String? targetCollection;

  const WebRemoteUrlImportResult({
    required this.importedCount,
    required this.skippedCount,
    required this.failedCount,
    this.taggedCount = 0,
    this.organizedCount = 0,
    this.rescannedCount = 0,
    this.targetCollection,
  });

  bool get hasChanges => importedCount > 0 || organizedCount > 0;
}

class WebSearchQuery {
  final String raw;
  final String? q;
  final String? artist;
  final String? series;
  final String? character;
  final String? mediaType;
  final String? name;
  final bool untagged;

  const WebSearchQuery({
    required this.raw,
    this.q,
    this.artist,
    this.series,
    this.character,
    this.mediaType,
    this.name,
    this.untagged = false,
  });
}

class WebSearchParser {
  static WebSearchQuery parse(String rawQuery) {
    final trimmed = rawQuery.trim();
    if (trimmed.isEmpty) {
      return const WebSearchQuery(raw: '');
    }

    String? q;
    String? artist;
    String? series;
    String? character;
    String? mediaType;
    String? name;
    var untagged = false;
    final freeTokens = <String>[];

    for (final token in _tokenize(trimmed)) {
      final colonIndex = token.indexOf(':');
      if (colonIndex <= 0) {
        final normalized = token.trim();
        if (normalized.toLowerCase() == 'untagged') {
          untagged = true;
        } else if (normalized.startsWith('#')) {
          final tagName = normalized.substring(1).trim();
          if (tagName.isNotEmpty) {
            freeTokens.add(tagName);
          }
        } else if (normalized.isNotEmpty) {
          freeTokens.add(_unquote(normalized));
        }
        continue;
      }

      final key = token.substring(0, colonIndex).trim().toLowerCase();
      final value = _unquote(token.substring(colonIndex + 1).trim());
      if (value.isEmpty) {
        continue;
      }

      switch (key) {
        case 'artist':
          artist = _appendValue(artist, value);
          break;
        case 'series':
          series = _appendValue(series, value);
          break;
        case 'character':
          character = _appendValue(character, value);
          break;
        case 'name':
          name = _appendValue(name, value);
          break;
        case 'type':
        case 'kind':
        case 'mediatype':
          mediaType = _normalizeMediaType(value);
          break;
        default:
          freeTokens.add(_unquote(token));
          break;
      }
    }

    if (freeTokens.isNotEmpty) {
      q = freeTokens.join(' ');
    }

    return WebSearchQuery(
      raw: trimmed,
      q: q,
      artist: artist,
      series: series,
      character: character,
      mediaType: mediaType,
      name: name,
      untagged: untagged,
    );
  }

  static String formatTagQuery(Tag tag) {
    final value = _quoteIfNeeded(tag.name.trim());
    switch (tag.category) {
      case TagCategory.artist:
        return 'artist:$value';
      case TagCategory.series:
        return 'series:$value';
      case TagCategory.mediaType:
        return 'type:$value';
      case TagCategory.character:
        return 'character:$value';
      case TagCategory.free:
        return '#${tag.name.trim()}';
    }
  }

  static String _appendValue(String? current, String value) {
    if (current == null || current.isEmpty) {
      return value;
    }
    return '$current $value';
  }

  static List<String> _tokenize(String input) {
    final tokens = <String>[];
    var buffer = StringBuffer();
    String? quote;

    for (final rune in input.runes) {
      final char = String.fromCharCode(rune);
      if (quote != null) {
        buffer.write(char);
        if (char == quote) {
          quote = null;
        }
        continue;
      }

      if (char == '"' || char == "'") {
        quote = char;
        buffer.write(char);
        continue;
      }

      if (char.trim().isEmpty) {
        if (buffer.isNotEmpty) {
          tokens.add(buffer.toString());
          buffer = StringBuffer();
        }
        continue;
      }

      buffer.write(char);
    }

    if (buffer.isNotEmpty) {
      tokens.add(buffer.toString());
    }

    return tokens;
  }

  static String _unquote(String value) {
    final trimmed = value.trim();
    if (trimmed.length >= 2 &&
        ((trimmed.startsWith('"') && trimmed.endsWith('"')) ||
            (trimmed.startsWith("'") && trimmed.endsWith("'")))) {
      return trimmed.substring(1, trimmed.length - 1).replaceAll(r'\"', '"');
    }
    return trimmed;
  }

  static String _quoteIfNeeded(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return '""';
    }
    if (!RegExp(r'[\s:#"]').hasMatch(trimmed)) {
      return trimmed;
    }
    return '"${trimmed.replaceAll('"', r'\"')}"';
  }

  static String? _normalizeMediaType(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'image':
      case 'images':
        return 'image';
      case 'pdf':
        return 'pdf';
      default:
        return null;
    }
  }
}

class WebRemoteApiClient {
  final String baseUrl;
  final String? authToken;
  final Duration timeout;
  final Duration actionTimeout;
  Future<List<WebRemoteFolder>>? _foldersFuture;
  final Map<String, Future<List<WebRemoteEntry>>> _folderChildrenCache =
      <String, Future<List<WebRemoteEntry>>>{};
  final Map<String, Future<List<WebRemoteEntry>>> _searchCache =
      <String, Future<List<WebRemoteEntry>>>{};
  final Map<String, Future<List<Tag>>> _itemTagsCache =
      <String, Future<List<Tag>>>{};
  final Map<String, Future<WebRemoteMediaMeta>> _mediaMetaCache =
      <String, Future<WebRemoteMediaMeta>>{};
  final Map<String, Future<WebRemotePdfPageCountInfo>> _pdfPageCountCache =
      <String, Future<WebRemotePdfPageCountInfo>>{};
  final Map<String, Future<Uint8List>> _pdfBytesCache =
      <String, Future<Uint8List>>{};

  WebRemoteApiClient({
    required this.baseUrl,
    this.authToken,
    this.timeout = const Duration(seconds: 20),
    this.actionTimeout = const Duration(minutes: 10),
  });

  void clearCaches() {
    _foldersFuture = null;
    _folderChildrenCache.clear();
    _searchCache.clear();
    _itemTagsCache.clear();
    _mediaMetaCache.clear();
    _pdfPageCountCache.clear();
    _pdfBytesCache.clear();
  }

  Future<T> _memoize<T>(
    Map<String, Future<T>> cache,
    String key,
    Future<T> Function() loader,
  ) {
    final existing = cache[key];
    if (existing != null) {
      return existing;
    }
    final future = loader();
    cache[key] = future;
    future.catchError((_) {
      if (identical(cache[key], future)) {
        cache.remove(key);
      }
    });
    return future;
  }

  String _cacheKey(String path, {Map<String, String>? queryParameters}) {
    final uri = Uri(
      path: path,
      queryParameters: queryParameters == null || queryParameters.isEmpty
          ? null
          : Map<String, String>.fromEntries(
              queryParameters.entries.toList()
                ..sort((left, right) => left.key.compareTo(right.key)),
            ),
    );
    return uri.toString();
  }

  bool _shouldRetryRequest(String method, WebRemoteException error) {
    if (method.toUpperCase() != 'GET') {
      return false;
    }
    final statusCode = error.statusCode;
    if (statusCode == null) {
      return true;
    }
    return statusCode == 408 ||
        statusCode == 425 ||
        statusCode == 429 ||
        statusCode == 500 ||
        statusCode == 502 ||
        statusCode == 503 ||
        statusCode == 504;
  }

  Future<T> _runGetWithRetry<T>(
    String method,
    Future<T> Function() loader,
  ) async {
    WebRemoteException? lastError;
    for (var attempt = 0; attempt < 2; attempt += 1) {
      try {
        return await loader();
      } on WebRemoteException catch (error) {
        if (attempt > 0 || !_shouldRetryRequest(method, error)) {
          rethrow;
        }
        lastError = error;
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
    }
    throw lastError ?? const WebRemoteException('サーバーへの接続に失敗しました');
  }

  Future<void> checkHealth() async {
    final json = await _getJson('/health');
    if (json is! Map<String, dynamic> || json['ok'] != true) {
      throw const WebRemoteException('サーバーの応答を確認できませんでした');
    }
  }

  Future<List<WebRemoteFolder>> listFolders({bool refresh = false}) async {
    if (refresh) {
      _foldersFuture = null;
    }
    final existing = _foldersFuture;
    if (existing != null) {
      return existing;
    }
    final future = () async {
      final json = await _getJson('/folders');
      return _unwrapItems(json)
          .whereType<Map>()
          .map(_parseFolder)
          .where((folder) => folder.raw.trim().isNotEmpty)
          .toList(growable: false);
    }();
    _foldersFuture = future;
    future.catchError((_) {
      if (identical(_foldersFuture, future)) {
        _foldersFuture = null;
      }
    });
    return future;
  }

  Future<List<WebRemoteEntry>> listFolderChildren(
    String folderRaw, {
    int limit = 200,
    int offset = 0,
  }) async {
    final queryParameters = <String, String>{
      'folderRaw': folderRaw,
      'limit': '$limit',
      'offset': '$offset',
    };
    return _memoize(
      _folderChildrenCache,
      _cacheKey('/folders/children', queryParameters: queryParameters),
      () async {
        final json = await _getJson(
          '/folders/children',
          queryParameters: queryParameters,
        );
        return _unwrapItems(
          json,
        ).whereType<Map>().map(_parseEntry).toList(growable: false);
      },
    );
  }

  Future<List<WebRemoteEntry>> search(
    WebSearchQuery query, {
    String? folderRaw,
    int limit = 200,
    int offset = 0,
  }) async {
    final path = query.untagged ? '/untagged' : '/search';
    final queryParameters = <String, String>{
      if (folderRaw != null && folderRaw.trim().isNotEmpty)
        'folderRaw': folderRaw,
      if (!query.untagged && query.q != null && query.q!.isNotEmpty)
        'q': query.q!,
      if (!query.untagged && query.artist != null && query.artist!.isNotEmpty)
        'artist': query.artist!,
      if (!query.untagged && query.series != null && query.series!.isNotEmpty)
        'series': query.series!,
      if (!query.untagged &&
          query.character != null &&
          query.character!.isNotEmpty)
        'character': query.character!,
      if (!query.untagged &&
          query.mediaType != null &&
          query.mediaType!.isNotEmpty)
        'mediaType': query.mediaType!,
      if (!query.untagged && query.name != null && query.name!.isNotEmpty)
        'name': query.name!,
      'limit': '$limit',
      'offset': '$offset',
    };

    return _memoize(
      _searchCache,
      _cacheKey(path, queryParameters: queryParameters),
      () async {
        final json = await _getJson(path, queryParameters: queryParameters);
        return _unwrapItems(
          json,
        ).whereType<Map>().map(_parseEntry).toList(growable: false);
      },
    );
  }

  Future<List<Tag>> fetchItemTags(String mediaId) async {
    return _memoize(_itemTagsCache, mediaId, () async {
      final json = await _getJson(
        '/items/${Uri.encodeComponent(mediaId)}/tags',
      );
      return _unwrapItems(
        json,
      ).whereType<Map>().map(_parseTag).toList(growable: false);
    });
  }

  Future<void> requestRescan({String? folderRaw}) async {
    final trimmedFolder = folderRaw?.trim();
    await _postJson('/rescan', <String, dynamic>{
      if (trimmedFolder != null && trimmedFolder.isNotEmpty)
        'folderRaw': trimmedFolder,
    }, requestTimeout: actionTimeout);
    clearCaches();
  }

  Future<WebRemoteOrganizeResult> organizeLibrary(String folderRaw) async {
    final json = await _postJson('/organize', <String, dynamic>{
      'folderRaw': folderRaw,
    }, requestTimeout: actionTimeout);
    if (json is! Map<String, dynamic>) {
      throw const WebRemoteException('整理結果の形式が不正です');
    }

    final moved = <String, String>{};
    final movedRaw = json['moved'];
    if (movedRaw is Map) {
      movedRaw.forEach((key, value) {
        final before = key?.toString().trim() ?? '';
        final after = value?.toString().trim() ?? '';
        if (before.isEmpty || after.isEmpty) {
          return;
        }
        moved[before] = after;
      });
    }

    final result = WebRemoteOrganizeResult(
      moved: moved,
      movedCount: _asInt(json['movedCount']) ?? moved.length,
      rescannedCount: _asInt(json['rescannedCount']) ?? 0,
    );
    clearCaches();
    return result;
  }

  Future<WebRemoteUrlImportResult> downloadUrl({
    required String folderRaw,
    required String sourceUrl,
    UrlImportOptions? options,
    ImportMetadata? importMetadata,
  }) async {
    final effectiveOptions = options ?? const UrlImportOptions();
    final sourceUrls = effectiveOptions.collectSourceUrls(sourceUrl);
    final artistTag = importMetadata?.artistTag?.trim();
    final seriesTag = importMetadata?.seriesTag?.trim();
    final targetCollection = importMetadata?.targetCollection?.trim();
    final cookieFilePath = effectiveOptions.normalizedCookieFilePath;
    final urlListFilePath = effectiveOptions.normalizedUrlListFilePath;
    final favoriteSites = effectiveOptions.normalizedFavoriteSites;
    final favoriteUserServices =
        effectiveOptions.normalizedFavoriteUserServices;

    final json = await _postJson('/download-url', <String, dynamic>{
      'folderRaw': folderRaw,
      'url': sourceUrl,
      'urls': sourceUrls,
      if (cookieFilePath != null) 'cookieFilePath': cookieFilePath,
      'cookieMode': effectiveOptions.cookieMode.apiValue,
      if (urlListFilePath != null) 'urlListFilePath': urlListFilePath,
      if (favoriteSites.isNotEmpty) 'sites': favoriteSites,
      'favoritePosts': effectiveOptions.favoritePosts,
      if (favoriteUserServices.isNotEmpty)
        'favoriteUserServices': favoriteUserServices,
      'mediaType': effectiveOptions.mediaType.apiValue,
      'parallelDownloads': effectiveOptions.effectiveParallelDownloads,
      'inline': effectiveOptions.includeInlineImages,
      'content': effectiveOptions.includePostContent,
      'comments': effectiveOptions.includeComments,
      'saveJson': effectiveOptions.saveJson,
      'overwrite': effectiveOptions.overwriteExistingFiles,
      'verbose': effectiveOptions.verbose,
      'convertHitomiToPdf': effectiveOptions.convertHitomiToPdf,
      'preferHitomiOriginal': effectiveOptions.preferHitomiOriginal,
      if (artistTag != null && artistTag.isNotEmpty) 'artistTag': artistTag,
      if (seriesTag != null && seriesTag.isNotEmpty) 'seriesTag': seriesTag,
      if (importMetadata != null && importMetadata.freeTags.isNotEmpty)
        'freeTags': importMetadata.freeTags,
      if (importMetadata != null && importMetadata.characterTags.isNotEmpty)
        'characterTags': importMetadata.characterTags,
      if (targetCollection != null && targetCollection.isNotEmpty)
        'targetCollection': targetCollection,
      'organizeAfterImport': importMetadata?.organizeAfterImport ?? false,
    }, requestTimeout: actionTimeout);

    if (json is! Map<String, dynamic>) {
      throw const WebRemoteException('URL 取り込み結果の形式が不正です');
    }

    final result = WebRemoteUrlImportResult(
      importedCount: _asInt(json['importedCount']) ?? 0,
      skippedCount: _asInt(json['skippedCount']) ?? 0,
      failedCount: _asInt(json['failedCount']) ?? 0,
      taggedCount: _asInt(json['taggedCount']) ?? 0,
      organizedCount: _asInt(json['organizedCount']) ?? 0,
      rescannedCount: _asInt(json['rescannedCount']) ?? 0,
      targetCollection: json['targetCollection']?.toString(),
    );
    clearCaches();
    return result;
  }

  Future<WebRemoteMediaMeta> fetchMediaMeta(String mediaId) async {
    return _memoize(_mediaMetaCache, mediaId, () async {
      final json = await _getJson(
        '/media/${Uri.encodeComponent(mediaId)}/meta',
      );
      if (json is! Map<String, dynamic>) {
        throw const WebRemoteException('メディア情報の形式が不正です');
      }
      return WebRemoteMediaMeta(
        mediaId: json['mediaId']?.toString() ?? mediaId,
        displayName: json['displayName']?.toString() ?? mediaId,
        kind: json['kind']?.toString() ?? 'image',
        mimeType: json['mimeType']?.toString(),
        sizeBytes: _asInt(json['sizeBytes']),
        modifiedAt: _parseDateTime(json['modifiedAt']),
        etag: json['etag']?.toString(),
        supportsRange: json['supportsRange'] == true,
        pageCount: _asInt(json['pageCount']),
        stats: _parseMediaStats(json['stats']),
      );
    });
  }

  Future<WebRemoteMediaStats> recordMediaView(String mediaId) async {
    final json = await _postJson(
      '/media/${Uri.encodeComponent(mediaId)}/view',
      const <String, dynamic>{},
    );
    final stats = json is Map<String, dynamic> ? _parseMediaStats(json) : null;
    if (stats == null) {
      throw const WebRemoteException('Invalid media stats response');
    }
    _mediaMetaCache.remove(mediaId);
    _searchCache.clear();
    _folderChildrenCache.clear();
    return stats;
  }

  Future<List<WebRemoteMediaActivityEntry>> fetchRecentMediaActivity({
    int limit = 24,
  }) async {
    final json = await _getJson(
      '/activity/recent',
      queryParameters: <String, String>{'limit': '${limit < 1 ? 1 : limit}'},
    );
    final items = (json is Map<String, dynamic> ? json['items'] : null);
    if (items is! List) {
      return const <WebRemoteMediaActivityEntry>[];
    }
    return items
        .whereType<Map>()
        .map((raw) => _parseMediaActivityEntry(Map<String, dynamic>.from(raw)))
        .toList(growable: false);
  }

  Future<ReadingProgressEntry?> fetchReadingProgress(String mediaId) async {
    try {
      final json = await _getJson('/progress/${Uri.encodeComponent(mediaId)}');
      if (json is! Map<String, dynamic>) {
        throw const WebRemoteException('読書進捗の形式が不正です');
      }
      return _parseReadingProgressEntry(json);
    } on WebRemoteException catch (error) {
      if (error.statusCode == 404) {
        return null;
      }
      rethrow;
    }
  }

  Future<List<ReadingProgressEntry>> fetchRecentReadingProgress({
    int limit = 24,
  }) async {
    final json = await _getJson(
      '/progress/recent',
      queryParameters: <String, String>{'limit': '${limit < 1 ? 1 : limit}'},
    );
    final items = (json is Map<String, dynamic> ? json['items'] : null);
    if (items is! List) {
      return const <ReadingProgressEntry>[];
    }
    return items
        .whereType<Map>()
        .map(
          (raw) => _parseReadingProgressEntry(Map<String, dynamic>.from(raw)),
        )
        .toList(growable: false);
  }

  Future<ReadingProgressEntry> upsertReadingProgress(
    String mediaId, {
    required int currentPage,
    int? totalPages,
    double? progress,
    DateTime? lastReadAt,
    DateTime? updatedAt,
    Map<String, dynamic>? identity,
  }) async {
    final json = await _putJson(
      '/progress/${Uri.encodeComponent(mediaId)}',
      <String, dynamic>{
        'currentPage': currentPage,
        if (totalPages != null) 'totalPages': totalPages,
        if (progress != null) 'progress': progress,
        if (lastReadAt != null)
          'lastReadAt': lastReadAt.toUtc().toIso8601String(),
        if (updatedAt != null) 'updatedAt': updatedAt.toUtc().toIso8601String(),
        if (identity != null) 'identity': identity,
      },
    );
    if (json is! Map<String, dynamic>) {
      throw const WebRemoteException('読書進捗の形式が不正です');
    }
    return _parseReadingProgressEntry(json);
  }

  Future<WebRemoteMediaActivityEntry> recordMediaActivity(
    String mediaId, {
    int? lastPage,
    int? totalPages,
  }) async {
    final json = await _postJson(
      '/media/${Uri.encodeComponent(mediaId)}/activity',
      <String, dynamic>{
        if (lastPage != null) 'lastPage': lastPage,
        if (totalPages != null) 'totalPages': totalPages,
      },
    );
    if (json is! Map<String, dynamic>) {
      throw const WebRemoteException('Invalid media activity response');
    }
    return _parseMediaActivityEntry(json);
  }

  Future<Uint8List> fetchThumbnail(
    String mediaId, {
    int? width,
    int? height,
    int? page,
    bool refresh = false,
  }) async {
    try {
      return await _getBytes(
        '/media/${Uri.encodeComponent(mediaId)}/thumb',
        queryParameters: <String, String>{
          if (width != null) 'width': '$width',
          if (height != null) 'height': '$height',
          if (page != null) 'page': '$page',
          if (refresh) 'refresh': '${DateTime.now().microsecondsSinceEpoch}',
        },
      );
    } on WebRemoteException catch (error) {
      if (page == null || error.statusCode == 401 || error.statusCode == 403) {
        rethrow;
      }
      return _renderPdfPageLocally(mediaId, page, width: width);
    }
  }

  Future<Uint8List> fetchPdfPage(String mediaId, int pageNo, {int? width}) {
    return _getBytes(
      '/media/${Uri.encodeComponent(mediaId)}/page/$pageNo',
      queryParameters: <String, String>{if (width != null) 'width': '$width'},
    );
  }

  List<int> _pdfRenderWidthCandidates(int? requestedWidth) {
    final candidates = <int>[];

    void addCandidate(int? value) {
      final normalized = value ?? 0;
      if (normalized < 128 || candidates.contains(normalized)) {
        return;
      }
      candidates.add(normalized);
    }

    addCandidate(requestedWidth);
    if (requestedWidth == null || requestedWidth > 1280) {
      addCandidate(1280);
    }
    if (requestedWidth == null || requestedWidth > 960) {
      addCandidate(960);
    }
    if (requestedWidth == null || requestedWidth > 720) {
      addCandidate(720);
    }
    if (candidates.isEmpty) {
      candidates.add(960);
    }
    return candidates;
  }

  Future<Uint8List> fetchRenderedPdfPage(
    String mediaId,
    int pageNo, {
    int? width,
  }) async {
    final widthCandidates = _pdfRenderWidthCandidates(width);
    WebRemoteException? lastError;

    for (final candidateWidth in widthCandidates) {
      try {
        return await fetchPdfPage(mediaId, pageNo, width: candidateWidth);
      } on WebRemoteException catch (error) {
        lastError = error;
      }
    }

    for (final candidateWidth in widthCandidates) {
      try {
        return await fetchThumbnail(
          mediaId,
          width: candidateWidth,
          page: pageNo,
          refresh: true,
        );
      } on WebRemoteException catch (error) {
        lastError = error;
      }
    }

    throw lastError ?? const WebRemoteException('PDF ページ画像の取得に失敗しました');
  }

  Future<Uint8List> _fetchPdfBytesForLocalRender(String mediaId) {
    return _memoize(_pdfBytesCache, mediaId, () => fetchImageDownload(mediaId));
  }

  Future<Uint8List> _renderPdfPageLocally(
    String mediaId,
    int pageNo, {
    int? width,
  }) async {
    if (pageNo < 1) {
      throw const WebRemoteException(
        'pageNo must be greater than or equal to 1',
        statusCode: 400,
      );
    }

    PdfDocument? document;
    PdfPage? page;
    try {
      await _ensurePdfJsReady();
      final pdfBytes = await _fetchPdfBytesForLocalRender(mediaId);
      document = await PdfDocument.openData(pdfBytes);
      if (pageNo > document.pagesCount) {
        throw const WebRemoteException(
          'pageNo is out of range',
          statusCode: 400,
        );
      }

      page = await document.getPage(pageNo);
      final targetWidth = ((width ?? 1200).clamp(128, 2400) as num).toDouble();
      final pageWidth = page.width <= 0 ? 1.0 : page.width;
      final targetHeight = page.height * (targetWidth / pageWidth);
      final image = await page.render(
        width: targetWidth,
        height: targetHeight,
        format: PdfPageImageFormat.png,
        backgroundColor: '#FFFFFF',
      );
      if (image == null) {
        throw const WebRemoteException('PDF render failed');
      }
      return image.bytes;
    } on WebRemoteException {
      rethrow;
    } catch (error) {
      throw WebRemoteException('PDF.js render failed: $error');
    } finally {
      await page?.close();
      await document?.close();
    }
  }

  Future<WebRemotePdfPageCountInfo> resolvePdfPageCountInfo(
    String mediaId, {
    int? pageCountHint,
  }) async {
    final cacheKey = '$mediaId:${pageCountHint ?? 0}';
    return _memoize(_pdfPageCountCache, cacheKey, () async {
      if (pageCountHint != null && pageCountHint > 0) {
        return WebRemotePdfPageCountInfo(
          count: pageCountHint,
          isReliable: true,
        );
      }

      return WebRemotePdfPageCountInfo(
        count: await _resolvePdfPageCountByPageProbe(mediaId),
        isReliable: false,
      );
    });
  }

  Future<int> resolvePdfPageCount(String mediaId, {int? pageCountHint}) async {
    final info = await resolvePdfPageCountInfo(
      mediaId,
      pageCountHint: pageCountHint,
    );
    return info.count;
  }

  Future<int> _resolvePdfPageCountByPageProbe(String mediaId) async {
    if (!await _pdfPageExists(mediaId, 1)) {
      return 1;
    }

    var low = 1;
    var high = 2;
    while (await _pdfPageExists(mediaId, high)) {
      low = high;
      if (high >= 4096) {
        return high;
      }
      high *= 2;
    }

    while (low + 1 < high) {
      final mid = low + ((high - low) ~/ 2);
      if (await _pdfPageExists(mediaId, mid)) {
        low = mid;
      } else {
        high = mid;
      }
    }

    return low;
  }

  Future<bool> _pdfPageExists(String mediaId, int pageNo) async {
    try {
      await fetchThumbnail(mediaId, width: 64, height: 64, page: pageNo);
      return true;
    } on WebRemoteException catch (error) {
      final statusCode = error.statusCode;
      if (statusCode != null && statusCode != 401 && statusCode != 403) {
        return false;
      }
      rethrow;
    }
  }

  Future<Uint8List> fetchImageDownload(String mediaId) {
    return _getBytes(
      '/media/${Uri.encodeComponent(mediaId)}/download',
      requestTimeout: actionTimeout,
    );
  }

  Uri buildMediaDownloadUri(String mediaId) {
    return _buildUri('/media/${Uri.encodeComponent(mediaId)}/download');
  }

  Future<String> createPdfObjectUrl(String mediaId) async {
    final bytes = await fetchImageDownload(mediaId);
    final blob = html.Blob(<Object>[bytes], 'application/pdf');
    return html.Url.createObjectUrlFromBlob(blob);
  }

  void revokeObjectUrl(String objectUrl) {
    html.Url.revokeObjectUrl(objectUrl);
  }

  Future<void> openPdfInNewTab(String mediaId) async {
    final token = authToken?.trim();
    if (token == null || token.isEmpty) {
      html.window.open(buildMediaDownloadUri(mediaId).toString(), '_blank');
      return;
    }

    final popup = html.window.open('', '_blank');
    final objectUrl = await createPdfObjectUrl(mediaId);
    popup.location.href = objectUrl;
    unawaited(
      Future<void>.delayed(
        const Duration(minutes: 2),
        () => revokeObjectUrl(objectUrl),
      ),
    );
  }

  Future<dynamic> _getJson(
    String path, {
    Map<String, String>? queryParameters,
  }) async {
    final raw = await _requestText(
      'GET',
      path,
      queryParameters: queryParameters,
    );
    if (raw.trim().isEmpty) {
      return <String, dynamic>{};
    }
    return jsonDecode(raw);
  }

  Future<dynamic> _postJson(
    String path,
    Map<String, dynamic> body, {
    Map<String, String>? queryParameters,
    Duration? requestTimeout,
  }) async {
    final raw = await _requestText(
      'POST',
      path,
      queryParameters: queryParameters,
      body: body,
      requestTimeout: requestTimeout,
    );
    if (raw.trim().isEmpty) {
      return <String, dynamic>{};
    }
    return jsonDecode(raw);
  }

  Future<dynamic> _putJson(
    String path,
    Map<String, dynamic> body, {
    Map<String, String>? queryParameters,
    Duration? requestTimeout,
  }) async {
    final raw = await _requestText(
      'PUT',
      path,
      queryParameters: queryParameters,
      body: body,
      requestTimeout: requestTimeout,
    );
    if (raw.trim().isEmpty) {
      return <String, dynamic>{};
    }
    return jsonDecode(raw);
  }

  Future<dynamic> _deleteJson(
    String path, {
    Map<String, String>? queryParameters,
    Duration? requestTimeout,
  }) async {
    final raw = await _requestText(
      'DELETE',
      path,
      queryParameters: queryParameters,
      requestTimeout: requestTimeout,
    );
    if (raw.trim().isEmpty) {
      return <String, dynamic>{};
    }
    return jsonDecode(raw);
  }

  Future<String> _requestText(
    String method,
    String path, {
    Map<String, String>? queryParameters,
    Map<String, dynamic>? body,
    Duration? requestTimeout,
  }) async {
    final effectiveTimeout = requestTimeout ?? timeout;
    return _runGetWithRetry(
      method,
      () => _requestTextOnce(
        method,
        path,
        queryParameters: queryParameters,
        body: body,
        requestTimeout: effectiveTimeout,
      ),
    );
  }

  Future<String> _requestTextOnce(
    String method,
    String path, {
    Map<String, String>? queryParameters,
    Map<String, dynamic>? body,
    required Duration requestTimeout,
  }) async {
    try {
      final request = await html.HttpRequest.request(
        _buildUri(path, queryParameters: queryParameters).toString(),
        method: method,
        sendData: body == null ? null : jsonEncode(body),
        requestHeaders: _buildHeaders(jsonBody: body != null),
      ).timeout(requestTimeout);

      final status = request.status ?? 0;
      final payload = request.responseText ?? '';
      if (status < 200 || status >= 300) {
        throw WebRemoteException(
          _extractErrorMessage(payload) ?? _messageForStatus(status),
          statusCode: status,
        );
      }

      return payload;
    } on TimeoutException {
      throw const WebRemoteException('サーバー応答がタイムアウトしました');
    } catch (error) {
      if (error is WebRemoteException) {
        rethrow;
      }
      throw const WebRemoteException(
        'サーバーに接続できません。CORS / HTTPS / トークン設定を確認してください',
      );
    }
  }

  Future<Uint8List> _getBytes(
    String path, {
    Map<String, String>? queryParameters,
    Duration? requestTimeout,
  }) async {
    final effectiveTimeout = requestTimeout ?? timeout;
    return _runGetWithRetry(
      'GET',
      () => _getBytesOnce(
        path,
        queryParameters: queryParameters,
        requestTimeout: effectiveTimeout,
      ),
    );
  }

  Future<Uint8List> _getBytesOnce(
    String path, {
    Map<String, String>? queryParameters,
    required Duration requestTimeout,
  }) async {
    try {
      final request = await html.HttpRequest.request(
        _buildUri(path, queryParameters: queryParameters).toString(),
        method: 'GET',
        responseType: 'arraybuffer',
        requestHeaders: _buildHeaders(),
      ).timeout(requestTimeout);

      final status = request.status ?? 0;
      final bytes = _responseBytes(request.response);
      if (status < 200 || status >= 300) {
        final raw = utf8.decode(bytes, allowMalformed: true);
        throw WebRemoteException(
          _extractErrorMessage(raw) ?? _messageForStatus(status),
          statusCode: status,
        );
      }

      final thumbnailStatus = request
          .getResponseHeader('X-Thumbnail-Status')
          ?.trim()
          .toLowerCase();
      if (thumbnailStatus == 'placeholder') {
        final detail =
            request.getResponseHeader('X-Thumbnail-Detail')?.trim() ??
            'Thumbnail placeholder returned';
        throw WebRemoteException(detail, statusCode: 503);
      }

      return bytes;
    } on TimeoutException {
      throw const WebRemoteException('サーバー応答がタイムアウトしました');
    } catch (error) {
      if (error is WebRemoteException) {
        rethrow;
      }
      throw const WebRemoteException(
        'サーバーに接続できません。CORS / HTTPS / トークン設定を確認してください',
      );
    }
  }

  Uri _buildUri(String path, {Map<String, String>? queryParameters}) {
    final trimmed = baseUrl.trim();
    if (trimmed.isEmpty) {
      throw const WebRemoteException('API URL が未設定です');
    }

    final baseUri = Uri.tryParse(trimmed);
    if (baseUri == null || !baseUri.hasScheme || baseUri.host.isEmpty) {
      throw const WebRemoteException('API URL の形式が不正です');
    }

    final left = baseUri.path.endsWith('/')
        ? baseUri.path.substring(0, baseUri.path.length - 1)
        : baseUri.path;
    final right = path.startsWith('/') ? path : '/$path';
    return baseUri.replace(
      path: '$left$right',
      queryParameters: queryParameters?.isEmpty == true
          ? null
          : queryParameters,
    );
  }

  Map<String, String> _buildHeaders({bool jsonBody = false}) {
    final headers = <String, String>{};
    if (jsonBody) {
      headers['Content-Type'] = 'application/json';
    }
    final token = authToken?.trim();
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  List<dynamic> _unwrapItems(dynamic json) {
    if (json is List) {
      return json;
    }
    if (json is Map<String, dynamic>) {
      final items = json['items'];
      if (items is List) {
        return items;
      }
      final results = json['results'];
      if (results is List) {
        return results;
      }
    }
    return const <dynamic>[];
  }

  WebRemoteFolder _parseFolder(Map raw) {
    return WebRemoteFolder(
      raw: raw['folderRaw']?.toString() ?? '',
      displayName: raw['displayName']?.toString() ?? '',
      lastScannedAt: _parseDateTime(raw['lastScannedAt']),
    );
  }

  WebRemoteEntry _parseEntry(Map raw) {
    return WebRemoteEntry(
      entryId:
          raw['entryId']?.toString() ??
          raw['mediaId']?.toString() ??
          raw['fullPath']?.toString() ??
          '',
      displayName: raw['displayName']?.toString() ?? '',
      folderRaw: raw['folderRaw']?.toString() ?? '',
      kind: raw['kind']?.toString() ?? 'image',
      mediaId: raw['mediaId']?.toString(),
      fullPath: raw['fullPath']?.toString(),
      sizeBytes: _asInt(raw['sizeBytes']),
      modifiedAt: _parseDateTime(raw['modifiedAt']),
      stats: _parseMediaStats(raw['stats']),
    );
  }

  Tag _parseTag(Map raw) {
    return Tag(
      name: raw['name']?.toString() ?? '',
      category: _parseTagCategory(raw['category']?.toString()),
    );
  }

  WebRemoteMediaStats? _parseMediaStats(dynamic raw) {
    if (raw is! Map) {
      return null;
    }
    final addedAt = _parseDateTime(raw['addedAt']);
    if (addedAt == null) {
      return null;
    }
    return WebRemoteMediaStats(
      addedAt: addedAt,
      lastViewedAt: _parseDateTime(raw['lastViewedAt']),
      viewCount: _asInt(raw['viewCount']) ?? 0,
    );
  }

  WebRemoteMediaActivityEntry _parseMediaActivityEntry(
    Map<String, dynamic> raw,
  ) {
    final viewedAt = _parseDateTime(raw['viewedAt']) ?? DateTime.now();
    final lastPage = _asInt(raw['lastPage']);
    return WebRemoteMediaActivityEntry(
      mediaId: raw['mediaId']?.toString() ?? '',
      folderRaw: raw['folderRaw']?.toString() ?? '',
      viewedAt: viewedAt,
      lastPage: lastPage != null && lastPage > 0 ? lastPage : null,
    );
  }

  ReadingProgressEntry _parseReadingProgressEntry(Map<String, dynamic> raw) {
    final currentPage =
        (_asInt(raw['currentPage']) ?? 1).clamp(1, 1 << 30) as int;
    final totalPages = _asInt(raw['totalPages']);
    final lastReadAt = _parseDateTime(raw['lastReadAt']) ?? DateTime.now();
    final updatedAt = _parseDateTime(raw['updatedAt']) ?? lastReadAt;
    return ReadingProgressEntry(
      mediaId: raw['mediaId']?.toString().trim() ?? '',
      title: raw['title']?.toString().trim() ?? '',
      folderRaw: raw['folderRaw']?.toString().trim() ?? '',
      currentPage: currentPage,
      totalPages: totalPages != null && totalPages > 0 ? totalPages : null,
      progress: ((_asDouble(raw['progress']) ?? 0.0).clamp(0.0, 1.0) as num)
          .toDouble(),
      lastReadAt: lastReadAt,
      updatedAt: updatedAt,
      thumbnailUrl: raw['thumbnailUrl']?.toString(),
    );
  }

  TagCategory _parseTagCategory(String? raw) {
    switch (raw?.trim().toLowerCase()) {
      case 'artist':
        return TagCategory.artist;
      case 'series':
        return TagCategory.series;
      case 'mediatype':
      case 'media_type':
      case 'type':
        return TagCategory.mediaType;
      case 'character':
        return TagCategory.character;
      default:
        return TagCategory.free;
    }
  }

  DateTime? _parseDateTime(dynamic raw) {
    final text = raw?.toString();
    if (text == null || text.trim().isEmpty) {
      return null;
    }
    return DateTime.tryParse(text);
  }

  int? _asInt(dynamic raw) {
    if (raw == null) {
      return null;
    }
    if (raw is int) {
      return raw;
    }
    return int.tryParse(raw.toString());
  }

  double? _asDouble(dynamic raw) {
    if (raw == null) {
      return null;
    }
    if (raw is num) {
      return raw.toDouble();
    }
    return double.tryParse(raw.toString());
  }

  Uint8List _responseBytes(Object? response) {
    if (response is ByteBuffer) {
      return Uint8List.view(response);
    }
    if (response is Uint8List) {
      return response;
    }
    if (response is List<int>) {
      return Uint8List.fromList(response);
    }
    return Uint8List(0);
  }

  String? _extractErrorMessage(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    try {
      final json = jsonDecode(trimmed);
      if (json is Map<String, dynamic>) {
        final message = json['message'] ?? json['error'] ?? json['detail'];
        if (message != null) {
          return message.toString();
        }
      }
    } catch (_) {
      return trimmed;
    }

    return null;
  }

  String _messageForStatus(int statusCode) {
    switch (statusCode) {
      case 401:
      case 403:
        return '認証に失敗しました。トークンを確認してください';
      case 404:
        return '対象が見つかりません';
      default:
        if (statusCode >= 500) {
          return 'サーバーエラーが発生しました';
        }
        if (statusCode == 0) {
          return 'サーバーへ接続できません';
        }
        return 'API エラー: HTTP $statusCode';
    }
  }
}
