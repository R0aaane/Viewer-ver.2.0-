import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../media_file_types.dart';
import '../repository/mediaRepository.dart';

class UrlImportDownloaderException implements Exception {
  final String message;

  const UrlImportDownloaderException(this.message);

  @override
  String toString() => message;
}

class LocalUrlDownloadResult {
  final int importedCount;
  final int skippedCount;
  final int failedCount;
  final List<String> logLines;
  final Map<String, HitomiGalleryMetadata> hitomiMetadataByRelativePath;

  const LocalUrlDownloadResult({
    required this.importedCount,
    this.skippedCount = 0,
    this.failedCount = 0,
    this.logLines = const <String>[],
    this.hitomiMetadataByRelativePath = const <String, HitomiGalleryMetadata>{},
  });
}

class HitomiSearchResult {
  final int galleryId;
  final String title;
  final String? type;
  final String? language;
  final String? date;
  final List<String> artists;
  final List<String> groups;
  final List<String> series;
  final List<String> characters;
  final List<String> tags;
  final String galleryUrl;
  final String? thumbnailUrl;
  final List<String> thumbnailUrls;
  final List<List<String>> previewUrlSets;

  const HitomiSearchResult({
    required this.galleryId,
    required this.title,
    this.type,
    this.language,
    this.date,
    this.artists = const <String>[],
    this.groups = const <String>[],
    this.series = const <String>[],
    this.characters = const <String>[],
    this.tags = const <String>[],
    required this.galleryUrl,
    this.thumbnailUrl,
    this.thumbnailUrls = const <String>[],
    this.previewUrlSets = const <List<String>>[],
  });
}

class HitomiSearchPage {
  final List<HitomiSearchResult> results;
  final int total;

  const HitomiSearchPage({required this.results, required this.total});
}

class HitomiSearchSuggestion {
  final String value;
  final int? count;
  final String namespace;

  const HitomiSearchSuggestion({
    required this.value,
    required this.namespace,
    this.count,
  });

  String get query => '$namespace:${value.replaceAll(RegExp(r'\s+'), '_')}';
}

class _PreparedUrlImportSources {
  final List<String> launcherUrls;
  final List<String> directUrls;
  final Map<String, HitomiGalleryMetadata> metadataByDirectUrl;

  const _PreparedUrlImportSources({
    this.launcherUrls = const <String>[],
    this.directUrls = const <String>[],
    this.metadataByDirectUrl = const <String, HitomiGalleryMetadata>{},
  });

  bool get hasLauncherUrls => launcherUrls.isNotEmpty;
  bool get hasDirectUrls => directUrls.isNotEmpty;
  bool get isEmpty => launcherUrls.isEmpty && directUrls.isEmpty;
}

class _ResolvedDirectUrl {
  final String url;
  final HitomiGalleryMetadata? metadata;

  const _ResolvedDirectUrl({required this.url, this.metadata});
}

class _HitomiSearchState {
  final String area;
  final String tag;
  final String language;
  final String orderBy;
  final String? orderByKey;
  final String orderByDirection;

  const _HitomiSearchState({
    this.area = 'all',
    this.tag = 'index',
    this.language = 'all',
    this.orderBy = 'date',
    this.orderByKey,
    this.orderByDirection = 'desc',
  });

  _HitomiSearchState copyWith({
    String? area,
    String? tag,
    String? language,
    String? orderBy,
    String? orderByKey,
    String? orderByDirection,
  }) {
    return _HitomiSearchState(
      area: area ?? this.area,
      tag: tag ?? this.tag,
      language: language ?? this.language,
      orderBy: orderBy ?? this.orderBy,
      orderByKey: orderByKey ?? this.orderByKey,
      orderByDirection: orderByDirection ?? this.orderByDirection,
    );
  }

  _HitomiSearchState normalized() {
    return copyWith(
      orderByKey: orderByKey ?? (orderBy == 'popular' ? 'year' : 'added'),
    );
  }
}

class _HitomiParsedSearchQuery {
  final _HitomiSearchState state;
  final List<String> positiveTerms;
  final List<String> negativeTerms;
  final List<List<String>> orTerms;

  const _HitomiParsedSearchQuery({
    required this.state,
    required this.positiveTerms,
    required this.negativeTerms,
    required this.orTerms,
  });
}

class UrlImportDownloaderService {
  static const String _uiEventPrefix = '__KEMONO_DL_UI__';
  static const String _contentDispositionHeader = 'content-disposition';
  static const String _standaloneUserAgent = 'pdf_viewer/standalone';
  static const String _mediaAcceptHeader = 'application/pdf,image/*,*/*;q=0.8';
  static const String _dddSmartHost = 'ddd-smart.net';
  static const String _dddSmartCdnHost = 'cdn.ddd-smart.net';
  static const List<String> _hitomiNozomiHosts = <String>[
    'ltn.gold-usergeneratedcontent.net',
  ];
  static const List<String> _hitomiGalleryInfoHosts = <String>[
    'ltn.gold-usergeneratedcontent.net',
  ];
  static const Set<String> _supportedHitomiSearchNamespaces = <String>{
    'artist',
    'group',
    'series',
    'character',
    'tag',
    'type',
    'language',
    'male',
    'female',
  };
  static const Set<String> _launcherSupportedHitomiSegments = <String>{
    'manga',
    'doujinshi',
    'cg',
    'gamecg',
    'imageset',
    'group',
    'galleries',
    'reader',
  };
  final Map<String, Future<List<int>>> _hitomiSearchIdsByQuery =
      <String, Future<List<int>>>{};

  Future<HitomiSearchPage> searchHitomiGalleryPage({
    required String query,
    required int offset,
    required int limit,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return const HitomiSearchPage(results: <HitomiSearchResult>[], total: 0);
    }
    final ids = await _hitomiSearchIdsByQuery.putIfAbsent(
      trimmed,
      () => _resolveHitomiSearchGalleryIds(trimmed),
    );
    final start = offset.clamp(0, ids.length).toInt();
    final end = (start + limit.clamp(1, 50)).clamp(0, ids.length).toInt();
    final pageIds = ids.sublist(start, end);
    final results = await _mapConcurrent<int, HitomiSearchResult>(
      pageIds,
      concurrency: 6,
      mapper: _fetchHitomiSearchResult,
    );
    return HitomiSearchPage(results: results, total: ids.length);
  }

  Future<List<HitomiSearchSuggestion>> searchHitomiSuggestions(
    String query, {
    int limit = 20,
  }) async {
    final parsed = _parseHitomiSuggestionQuery(query);
    if (parsed == null) {
      return const <HitomiSearchSuggestion>[];
    }
    final uri = Uri.https(
      'tagindex.hitomi.la',
      '/${parsed.field}/${parsed.pathSegments.join('/')}.json',
    );
    try {
      final bytes = await _downloadBytes(
        uri,
        accept: 'application/json,text/plain,*/*;q=0.8',
      );
      final decoded = jsonDecode(const Utf8Decoder().convert(bytes));
      if (decoded is! List) {
        return const <HitomiSearchSuggestion>[];
      }
      final suggestions = <HitomiSearchSuggestion>[];
      for (final entry in decoded.take(limit.clamp(1, 100))) {
        if (entry is! List || entry.length < 3) {
          continue;
        }
        final value = _trimmedOrNull(entry[0]);
        final namespace = _trimmedOrNull(entry[2]);
        if (value == null || namespace == null) {
          continue;
        }
        final count = entry[1] is num ? (entry[1] as num).toInt() : null;
        suggestions.add(
          HitomiSearchSuggestion(
            value: value,
            namespace: namespace,
            count: count,
          ),
        );
      }
      return suggestions;
    } on Object {
      return const <HitomiSearchSuggestion>[];
    }
  }

  Future<HitomiSearchResult> _fetchHitomiSearchResult(int galleryId) async {
    final galleryUrl = 'https://hitomi.la/galleries/$galleryId.html';
    for (final host in _hitomiGalleryInfoHosts) {
      try {
        final uri = Uri.https(host, '/galleries/$galleryId.js');
        final payload = await _downloadHtml(uri);
        final info = _decodeHitomiGalleryInfo(payload);
        if (info != null) {
          return _hitomiSearchResultFromInfo(
            galleryId: galleryId,
            galleryUrl: galleryUrl,
            info: info,
          );
        }
      } on Object {
        // Try the next Hitomi asset host.
      }
    }
    return HitomiSearchResult(
      galleryId: galleryId,
      title: 'Gallery $galleryId',
      galleryUrl: galleryUrl,
    );
  }

  HitomiSearchResult _hitomiSearchResultFromInfo({
    required int galleryId,
    required String galleryUrl,
    required Map<String, Object?> info,
  }) {
    final files = info['files'];
    String? thumbnailUrl;
    var thumbnailUrls = const <String>[];
    var previewUrlSets = const <List<String>>[];
    if (files is List && files.isNotEmpty) {
      previewUrlSets = files
          .whereType<Map>()
          .take(2)
          .map(
            (file) => _buildHitomiThumbnailUrls(
              file.cast<Object?, Object?>(),
            ),
          )
          .where((urls) => urls.isNotEmpty)
          .toList(growable: false);
      if (previewUrlSets.isNotEmpty) {
        thumbnailUrls = previewUrlSets.first;
        thumbnailUrl = thumbnailUrls.first;
      }
    }
    return HitomiSearchResult(
      galleryId: galleryId,
      title:
          _trimmedOrNull(info['japanese_title']) ??
          _trimmedOrNull(info['title']) ??
          _trimmedOrNull(info['english_title']) ??
          'Gallery $galleryId',
      type: _trimmedOrNull(info['type']),
      language:
          _trimmedOrNull(info['language_localname']) ??
          _firstHitomiFieldName(info['languages']) ??
          _trimmedOrNull(info['language']),
      date: _trimmedOrNull(info['date']),
      artists: _hitomiFieldNames(info['artists']),
      groups: _hitomiFieldNames(info['groups']),
      series: _hitomiFieldNames(info['series']).isNotEmpty
          ? _hitomiFieldNames(info['series'])
          : _hitomiFieldNames(info['parodys']),
      characters: _hitomiFieldNames(info['characters']),
      tags: _hitomiFieldNames(info['tags']),
      galleryUrl: galleryUrl,
      thumbnailUrl: thumbnailUrl,
      thumbnailUrls: thumbnailUrls,
      previewUrlSets: previewUrlSets,
    );
  }

  Map<String, Object?>? _decodeHitomiGalleryInfo(String payload) {
    final startMarker = RegExp(r'galleryinfo\s*=').firstMatch(payload);
    if (startMarker == null) {
      return null;
    }
    final braceStart = payload.indexOf('{', startMarker.end);
    if (braceStart < 0) {
      return null;
    }
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var index = braceStart; index < payload.length; index += 1) {
      final char = payload.codeUnitAt(index);
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (char == 0x5c) {
          escaped = true;
        } else if (char == 0x22) {
          inString = false;
        }
        continue;
      }
      if (char == 0x22) {
        inString = true;
      } else if (char == 0x7b) {
        depth += 1;
      } else if (char == 0x7d) {
        depth -= 1;
        if (depth == 0) {
          final decoded = jsonDecode(payload.substring(braceStart, index + 1));
          if (decoded is Map) {
            return decoded.cast<String, Object?>();
          }
          return null;
        }
      }
    }
    return null;
  }

  List<String> _buildHitomiThumbnailUrls(Map<Object?, Object?> file) {
    final hash = _trimmedOrNull(file['hash']);
    if (hash == null || hash.length < 3) {
      return const <String>[];
    }
    final name = _trimmedOrNull(file['name']);
    final originalExt = name == null
        ? 'jpg'
        : (name.split('.').lastOrNull ?? 'jpg').toLowerCase();
    final left = hash.substring(hash.length - 1);
    final right = hash.substring(hash.length - 3, hash.length - 1);
    final thumbPath = '$left/$right/$hash';
    final out = <String>[];
    for (final subdomain in const <String>['atn', 'btn', 'ctn']) {
      out.add(
        'https://$subdomain.gold-usergeneratedcontent.net/webpsmalltn/$thumbPath.webp',
      );
    }
    if (_trimmedOrNull(file['hasavif']) == '1') {
      for (final subdomain in const <String>['atn', 'btn', 'ctn']) {
        out.add(
          'https://$subdomain.gold-usergeneratedcontent.net/avifsmalltn/$thumbPath.avif',
        );
      }
    }
    for (final subdomain in const <String>['atn', 'btn', 'ctn']) {
      out.add(
        'https://$subdomain.gold-usergeneratedcontent.net/smalltn/$thumbPath.$originalExt',
      );
    }
    return out;
  }

  String? _firstHitomiFieldName(Object? value) {
    final values = _hitomiFieldNames(value);
    return values.isEmpty ? null : values.first;
  }

  List<String> _hitomiFieldNames(Object? value) {
    final out = <String>[];
    final seen = <String>{};
    void add(Object? raw) {
      final text = _trimmedOrNull(raw);
      if (text != null && seen.add(text.toLowerCase())) {
        out.add(text);
      }
    }

    if (value is List) {
      for (final entry in value) {
        if (entry is Map) {
          add(
            entry['name'] ??
                entry['artist'] ??
                entry['group'] ??
                entry['parody'] ??
                entry['character'] ??
                entry['tag'] ??
                entry['language_localname'],
          );
        } else {
          add(entry);
        }
      }
    } else if (value is Map) {
      add(
        value['name'] ??
            value['artist'] ??
            value['group'] ??
            value['parody'] ??
            value['character'] ??
            value['tag'] ??
            value['language_localname'],
      );
    } else {
      add(value);
    }
    return out;
  }

  Future<List<R>> _mapConcurrent<T, R>(
    List<T> items, {
    required int concurrency,
    required Future<R> Function(T item) mapper,
  }) async {
    if (items.isEmpty) {
      return <R>[];
    }
    final results = List<R?>.filled(items.length, null);
    var nextIndex = 0;
    Future<void> worker() async {
      while (nextIndex < items.length) {
        final index = nextIndex;
        nextIndex += 1;
        results[index] = await mapper(items[index]);
      }
    }

    await Future.wait<void>(
      List<Future<void>>.generate(concurrency.clamp(1, items.length), (_) {
        return worker();
      }),
    );
    return results.cast<R>();
  }

  Future<LocalUrlDownloadResult> downloadUrl({
    required String sourceUrl,
    required String destinationFolder,
    UrlImportOptions? options,
    void Function(MediaTransferProgress progress)? onProgress,
  }) async {
    final effectiveOptions = options ?? const UrlImportOptions();
    final prepared = await _prepareImportSources(sourceUrl, effectiveOptions);

    if (prepared.isEmpty && !effectiveOptions.hasFavoriteTargets) {
      throw const UrlImportDownloaderException(
        'No downloadable URLs were found',
      );
    }

    final launcherOptions = _copyOptionsWithoutUrlListFile(effectiveOptions);
    final directOptions = _copyOptionsForDirectDownload(effectiveOptions);
    final pendingDirectUrls = <String>[...prepared.directUrls];
    final directMetadataByUrl = <String, HitomiGalleryMetadata>{
      ...prepared.metadataByDirectUrl,
    };
    final results = <LocalUrlDownloadResult>[];
    UrlImportDownloaderException? lastLauncherMissingError;

    Future<void> runDirectUrls() async {
      if (pendingDirectUrls.isEmpty) {
        return;
      }
      final completedOffset = _totalHandledFiles(results);
      final result = await _runDirectUrlDownloadUrls(
        urls: pendingDirectUrls,
        destinationFolder: destinationFolder,
        options: directOptions,
        metadataByUrl: directMetadataByUrl,
        onProgress: _withProgressOffset(
          onProgress,
          completedOffset: completedOffset,
          trailingFiles: 0,
        ),
      );
      results.add(result);
    }

    final needsLauncherWork =
        effectiveOptions.hasFavoriteTargets || prepared.hasLauncherUrls;
    if (needsLauncherWork && _canUseLauncherFlow) {
      final launchers = <String>['python', 'py'];
      for (final launcher in launchers) {
        try {
          final launcherResults = await _runLauncherBatches(
            launcher: launcher,
            launcherUrls: prepared.launcherUrls,
            destinationFolder: destinationFolder,
            options: launcherOptions,
            hasFavoriteTargets: effectiveOptions.hasFavoriteTargets,
            completedOffset: _totalHandledFiles(results),
            trailingFiles: pendingDirectUrls.length,
            onProgress: onProgress,
          );
          results.addAll(launcherResults);
          await runDirectUrls();
          return _mergeDownloadResults(results);
        } on ProcessException catch (error) {
          stderr.writeln(
            '[url-import] launcher unavailable: $launcher ($error)',
          );
          lastLauncherMissingError = UrlImportDownloaderException(
            error.toString(),
          );
        } on UrlImportDownloaderException catch (error) {
          if (!_looksLikeMissingLauncher(error.message)) {
            rethrow;
          }
          stderr.writeln(
            '[url-import] launcher fallback: $launcher (${error.message})',
          );
          lastLauncherMissingError = error;
        }
      }
    }

    if (effectiveOptions.hasFavoriteTargets) {
      throw lastLauncherMissingError ??
          const UrlImportDownloaderException(
            'favorites 取得には Python ランチャーが必要です',
          );
    }

    if (prepared.hasLauncherUrls) {
      pendingDirectUrls.insertAll(0, prepared.launcherUrls);
    }
    await runDirectUrls();
    return _mergeDownloadResults(results);
  }

  Future<List<LocalUrlDownloadResult>> _runLauncherBatches({
    required String launcher,
    required List<String> launcherUrls,
    required String destinationFolder,
    required UrlImportOptions options,
    required bool hasFavoriteTargets,
    required int completedOffset,
    required int trailingFiles,
    void Function(MediaTransferProgress progress)? onProgress,
  }) async {
    if (hasFavoriteTargets || launcherUrls.length <= 1) {
      final result = await _runWithLauncher(
        launcher: launcher,
        sourceUrl: launcherUrls.join('\n'),
        destinationFolder: destinationFolder,
        options: options,
        onProgress: _withProgressOffset(
          onProgress,
          completedOffset: completedOffset,
          trailingFiles: trailingFiles,
        ),
      );
      return <LocalUrlDownloadResult>[result];
    }

    final batches = _chunkItems(
      launcherUrls,
      options.effectiveParallelDownloads.clamp(1, 8).toInt(),
    );
    final results = <LocalUrlDownloadResult>[];
    for (var index = 0; index < batches.length; index++) {
      final batch = batches[index];
      onProgress?.call(
        MediaTransferProgress(
          sentBytes: index,
          totalBytes: batches.length,
          completedFiles: index,
          totalFiles: batches.length,
          statusLabel: 'URL ダウンロード ${index + 1}/${batches.length} を処理しています',
        ),
      );
      final result = await _runWithLauncher(
        launcher: launcher,
        sourceUrl: batch.join('\n'),
        destinationFolder: destinationFolder,
        options: options,
        onProgress: _withProgressOffset(
          onProgress,
          completedOffset: completedOffset + _totalHandledFiles(results),
          trailingFiles: trailingFiles,
        ),
      );
      results.add(result);
    }
    return results;
  }

  bool get _canUseLauncherFlow => !Platform.isAndroid && !Platform.isIOS;

  Future<_PreparedUrlImportSources> _prepareImportSources(
    String sourceUrl,
    UrlImportOptions options,
  ) async {
    final launcherUrls = <String>[];
    final directUrls = <String>[];
    final metadataByDirectUrl = <String, HitomiGalleryMetadata>{};
    final launcherSeen = <String>{};
    final directSeen = <String>{};

    for (final rawUrl in await _collectInputUrls(sourceUrl, options)) {
      final expandedLauncherUrls = await _resolveExpandedLauncherUrls(rawUrl);
      if (expandedLauncherUrls != null) {
        for (final launcherUrl in expandedLauncherUrls) {
          if (launcherSeen.add(launcherUrl)) {
            launcherUrls.add(launcherUrl);
          }
        }
        continue;
      }

      final resolvedDirectUrl = await _resolveSpecialDirectUrl(rawUrl);
      if (resolvedDirectUrl != null) {
        if (directSeen.add(resolvedDirectUrl.url)) {
          directUrls.add(resolvedDirectUrl.url);
        }
        if (resolvedDirectUrl.metadata != null) {
          metadataByDirectUrl[resolvedDirectUrl.url] =
              resolvedDirectUrl.metadata!;
        }
        continue;
      }

      if (directSeen.add(rawUrl)) {
        directUrls.add(rawUrl);
      }
    }

    return _PreparedUrlImportSources(
      launcherUrls: launcherUrls,
      directUrls: directUrls,
      metadataByDirectUrl: metadataByDirectUrl,
    );
  }

  Future<List<String>?> _resolveExpandedLauncherUrls(String rawUrl) async {
    if (_supportsLauncherUrl(rawUrl)) {
      return <String>[rawUrl.trim()];
    }

    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return null;
    }
    if (uri.host.toLowerCase() != 'hitomi.la' || !_isHitomiSearchUrl(uri)) {
      return null;
    }

    return _resolveHitomiSearchLauncherUrls(uri);
  }

  bool _isHitomiSearchUrl(Uri uri) {
    final path = uri.path.toLowerCase();
    return path == '/search.html' || path.endsWith('/search.html');
  }

  Future<List<String>> _resolveHitomiSearchLauncherUrls(Uri uri) async {
    final queryText = Uri.decodeQueryComponent(uri.query).trim();
    if (queryText.isEmpty) {
      return const <String>[];
    }

    final galleryIds = await _resolveHitomiSearchGalleryIds(queryText);
    return galleryIds
        .map((galleryId) => 'https://hitomi.la/galleries/$galleryId.html')
        .toList(growable: false);
  }

  Future<List<int>> _resolveHitomiSearchGalleryIds(String queryText) async {
    final parsed = _parseHitomiSearchQuery(queryText);
    final state = parsed.state.normalized();
    final remainingPositiveTerms = <String>[...parsed.positiveTerms];

    late List<int> results;
    if (remainingPositiveTerms.isEmpty ||
        (!_isHitomiNamespacedTerm(remainingPositiveTerms.first) &&
            state.orderByKey != 'added')) {
      _assertSupportedHitomiSearchTerms(remainingPositiveTerms);
      results = await _downloadHitomiNozomiGalleryIds(state);
    } else {
      final firstTerm = remainingPositiveTerms.removeAt(0);
      results = await _resolveHitomiGalleryIdsForTerm(firstTerm, state);
    }

    for (final terms in parsed.orTerms) {
      if (terms.isEmpty) {
        continue;
      }
      final matchedIds = <int>{};
      for (final term in terms) {
        matchedIds.addAll(await _resolveHitomiGalleryIdsForTerm(term, state));
      }
      results = results.where(matchedIds.contains).toList(growable: false);
    }

    for (final term in remainingPositiveTerms) {
      final matchedIds = (await _resolveHitomiGalleryIdsForTerm(
        term,
        state,
      )).toSet();
      results = results.where(matchedIds.contains).toList(growable: false);
    }

    for (final term in parsed.negativeTerms) {
      final matchedIds = (await _resolveHitomiGalleryIdsForTerm(
        term,
        state,
      )).toSet();
      results = results
          .where((id) => !matchedIds.contains(id))
          .toList(growable: false);
    }

    if (state.orderByDirection == 'asc' ||
        state.orderByDirection == 'ascending') {
      return results.reversed.toList(growable: false);
    }
    return results;
  }

  _HitomiParsedSearchQuery _parseHitomiSearchQuery(String queryText) {
    var state = const _HitomiSearchState();
    final terms = _normalizeHitomiSearchTerms(queryText);
    final positiveTerms = <String>[];
    final negativeTerms = <String>[];
    var orTerms = <List<String>>[<String>[]];

    for (var index = 0; index < terms.length; index += 1) {
      final term = terms[index];
      final nextState = _nextHitomiSearchStateForOrderingTerm(term, state);
      if (nextState != null) {
        state = nextState;
        continue;
      }
      if (term == 'or') {
        continue;
      }

      final orPrevious = index > 0 && terms[index - 1] == 'or';
      final orNext = index + 1 < terms.length && terms[index + 1] == 'or';
      if (orPrevious || orNext) {
        orTerms.last.add(term);
        if (!orNext) {
          orTerms = <List<String>>[...orTerms, <String>[]];
        }
        continue;
      }

      if (term.startsWith('-')) {
        final negativeTerm = term.substring(1).trim();
        if (negativeTerm.isNotEmpty) {
          negativeTerms.add(negativeTerm);
        }
        continue;
      }
      positiveTerms.add(term);
    }

    positiveTerms.sort((left, right) {
      final leftNamespaced = _isHitomiNamespacedTerm(left);
      final rightNamespaced = _isHitomiNamespacedTerm(right);
      if (leftNamespaced == rightNamespaced) {
        return 0;
      }
      return leftNamespaced ? -1 : 1;
    });

    return _HitomiParsedSearchQuery(
      state: state,
      positiveTerms: positiveTerms,
      negativeTerms: negativeTerms,
      orTerms: orTerms
          .where((terms) => terms.isNotEmpty)
          .toList(growable: false),
    );
  }

  ({String field, List<String> pathSegments})? _parseHitomiSuggestionQuery(
    String query,
  ) {
    final normalized = query
        .trim()
        .toLowerCase()
        .replaceFirst(RegExp(r'^-'), '')
        .replaceAll('_', ' ');
    if (normalized.isEmpty) {
      return null;
    }
    var field = 'global';
    var term = normalized;
    final separatorIndex = normalized.indexOf(':');
    if (separatorIndex > 0) {
      field = normalized.substring(0, separatorIndex);
      term = normalized.substring(separatorIndex + 1).trim();
    }
    if (term.isEmpty) {
      return null;
    }
    final pathSegments = term
        .split('')
        .map(_encodeHitomiSuggestionPathSegment)
        .toList(growable: false);
    return (field: field, pathSegments: pathSegments);
  }

  String _encodeHitomiSuggestionPathSegment(String value) {
    return switch (value) {
      ' ' => '_',
      '/' => 'slash',
      '.' => 'dot',
      _ => value,
    };
  }

  List<String> _normalizeHitomiSearchTerms(String queryText) {
    final rawTerms = queryText
        .toLowerCase()
        .trim()
        .split(RegExp(r'\s+'))
        .where((term) => term.trim().isNotEmpty)
        .toList(growable: false);
    final terms = <String>[];
    for (var index = 0; index < rawTerms.length; index += 1) {
      var term = rawTerms[index];
      if (_isHitomiNamespacedTerm(term) || term.startsWith('-')) {
        while (index + 1 < rawTerms.length) {
          final next = rawTerms[index + 1];
          if (next == 'or' ||
              next.startsWith('-') ||
              _isHitomiNamespacedTerm(next) ||
              _nextHitomiSearchStateForOrderingTerm(
                    next,
                    const _HitomiSearchState(),
                  ) !=
                  null) {
            break;
          }
          term = '$term ${next.replaceAll('_', ' ')}';
          index += 1;
        }
      }
      terms.add(term.replaceAll('_', ' '));
    }
    return terms;
  }

  _HitomiSearchState? _nextHitomiSearchStateForOrderingTerm(
    String term,
    _HitomiSearchState current,
  ) {
    final separatorIndex = term.indexOf(':');
    if (separatorIndex <= 0) {
      return null;
    }
    final leftSide = term.substring(0, separatorIndex);
    final rightSide = term.substring(separatorIndex + 1);
    if (!RegExp(
      r'^(?:sort|order)(?:by)?(?:key|direction)?$',
    ).hasMatch(leftSide)) {
      return null;
    }

    applySwitch:
    switch (leftSide) {
      case 'orderbykey':
      case 'sortbykey':
      case 'orderkey':
      case 'sortkey':
        final orderByKey = rightSide.replaceAll(RegExp(r'[^0-9a-z]'), '');
        return current.copyWith(
          orderByKey: orderByKey,
          orderBy:
              const <String>{
                'week',
                'month',
                'year',
                'all',
                'today',
              }.contains(orderByKey)
              ? 'popular'
              : current.orderBy,
        );
      case 'orderby':
      case 'sortby':
        if (rightSide == 'popular' || rightSide == 'popularity') {
          return current.copyWith(orderBy: 'popular');
        }
        if (rightSide == 'date') {
          return current.copyWith(orderBy: 'date');
        }
        if (rightSide == 'datepublished') {
          return current.copyWith(orderBy: 'date', orderByKey: 'published');
        }
        if (rightSide == 'random' || rightSide == 'rand') {
          return current.copyWith(orderByDirection: 'random');
        }
        break applySwitch;
      case 'orderbydirection':
      case 'sortbydirection':
        return current.copyWith(
          orderByDirection: rightSide.replaceAll(RegExp(r'[^0-9a-z]'), ''),
        );
    }

    return null;
  }

  bool _isHitomiNamespacedTerm(String term) {
    final separatorIndex = term.indexOf(':');
    if (separatorIndex <= 0) {
      return false;
    }
    return _supportedHitomiSearchNamespaces.contains(
      term.substring(0, separatorIndex),
    );
  }

  void _assertSupportedHitomiSearchTerms(Iterable<String> terms) {
    for (final term in terms) {
      if (_isHitomiNamespacedTerm(term)) {
        continue;
      }
      throw UrlImportDownloaderException('Hitomi 検索 URL はタグ条件のみ対応しています: $term');
    }
  }

  Future<List<int>> _resolveHitomiGalleryIdsForTerm(
    String term,
    _HitomiSearchState state,
  ) async {
    _assertSupportedHitomiSearchTerms(<String>[term]);
    final separatorIndex = term.indexOf(':');
    final leftSide = term.substring(0, separatorIndex);
    final rightSide = term.substring(separatorIndex + 1).trim();
    final normalizedTerm = '$leftSide:$rightSide';

    switch (leftSide) {
      case 'female':
      case 'male':
        return _downloadHitomiNozomiGalleryIds(
          state.copyWith(area: 'tag', tag: normalizedTerm).normalized(),
        );
      case 'language':
        return _downloadHitomiNozomiGalleryIds(
          state.copyWith(language: rightSide).normalized(),
        );
      default:
        return _downloadHitomiNozomiGalleryIds(
          state.copyWith(area: leftSide, tag: rightSide).normalized(),
        );
    }
  }

  Future<List<int>> _downloadHitomiNozomiGalleryIds(
    _HitomiSearchState state,
  ) async {
    Object? lastError;
    for (final host in _hitomiNozomiHosts) {
      final uri = _buildHitomiNozomiUri(state, host: host);
      try {
        final bytes = await _downloadBytes(uri);
        final byteData = ByteData.sublistView(bytes);
        final galleryIds = <int>[];
        for (
          var offset = 0;
          offset + 4 <= byteData.lengthInBytes;
          offset += 4
        ) {
          galleryIds.add(byteData.getInt32(offset, Endian.big));
        }
        return galleryIds;
      } on UrlImportDownloaderException catch (error) {
        lastError = error;
      }
    }

    throw UrlImportDownloaderException(
      'Hitomi 検索 URL の解決に失敗しました: ${lastError ?? 'nozomi unavailable'}',
    );
  }

  Uri _buildHitomiNozomiUri(_HitomiSearchState state, {required String host}) {
    final normalized = state.normalized();
    final pathSegments = <String>['n'];
    if (normalized.orderBy != 'date' || normalized.orderByKey == 'published') {
      if (normalized.area == 'all') {
        pathSegments.addAll(<String>[
          normalized.orderBy,
          '${normalized.orderByKey}-${normalized.language}.nozomi',
        ]);
      } else {
        pathSegments.addAll(<String>[
          normalized.area,
          normalized.orderBy,
          normalized.orderByKey!,
          '${normalized.tag}-${normalized.language}.nozomi',
        ]);
      }
    } else if (normalized.area == 'all') {
      pathSegments.add('${normalized.tag}-${normalized.language}.nozomi');
    } else {
      pathSegments.addAll(<String>[
        normalized.area,
        '${normalized.tag}-${normalized.language}.nozomi',
      ]);
    }
    return Uri(scheme: 'https', host: host, pathSegments: pathSegments);
  }

  Future<LocalUrlDownloadResult> _runWithLauncher({
    required String launcher,
    required String sourceUrl,
    required String destinationFolder,
    UrlImportOptions? options,
    void Function(MediaTransferProgress progress)? onProgress,
  }) async {
    final effectiveOptions = options ?? const UrlImportOptions();
    final processArgs = <String>[
      '-X',
      'utf8',
      '-m',
      'server.kemono_download_task',
      '--dest',
      destinationFolder,
      ..._buildTaskArgs(sourceUrl, effectiveOptions),
    ];

    final process = await Process.start(
      launcher,
      processArgs,
      workingDirectory: Directory.current.path,
      runInShell: true,
      environment: <String, String>{'PYTHONUTF8': '1'},
    );

    final logLines = <String>[];
    var importedCount = 0;
    var skippedCount = 0;
    var failedCount = 0;
    final hitomiMetadataByRelativePath = <String, HitomiGalleryMetadata>{};
    var sawEvent = false;

    void appendLog(String line) {
      logLines.add(line);
      while (logLines.length > 80) {
        logLines.removeAt(0);
      }
    }

    Future<void> consumeStdout() async {
      await for (final line
          in process.stdout
              .transform(const Utf8Decoder(allowMalformed: true))
              .transform(const LineSplitter())) {
        if (line.startsWith(_uiEventPrefix)) {
          sawEvent = true;
          final payload = line.substring(_uiEventPrefix.length);
          try {
            final event = jsonDecode(payload);
            if (event is Map<String, dynamic>) {
              _storeHitomiMetadataEvent(
                event,
                destinationFolder: destinationFolder,
                out: hitomiMetadataByRelativePath,
              );
              importedCount = _asInt(event['success'], importedCount);
              skippedCount = _asInt(event['skipped'], skippedCount);
              failedCount = _asInt(event['failed'], failedCount);
              final completed = _asInt(event['completed'], 0);
              final total = _asInt(event['total'], 0);
              final currentFileName = event['current_file']?.toString();
              final statusLabel = event['status']?.toString();
              onProgress?.call(
                MediaTransferProgress(
                  sentBytes: completed,
                  totalBytes: total,
                  completedFiles: completed,
                  totalFiles: total,
                  currentFileName: currentFileName,
                  statusLabel: statusLabel,
                ),
              );
              continue;
            }
          } catch (_) {}
        }
        appendLog('[stdout] $line');
      }
    }

    Future<void> consumeStderr() async {
      await for (final line
          in process.stderr
              .transform(const Utf8Decoder(allowMalformed: true))
              .transform(const LineSplitter())) {
        appendLog('[stderr] $line');
      }
    }

    await Future.wait(<Future<void>>[consumeStdout(), consumeStderr()]);
    final exitCode = await process.exitCode;

    if (exitCode != 0) {
      throw UrlImportDownloaderException(
        logLines.isNotEmpty
            ? logLines.last
            : 'ダウンローダーが異常終了しました (exit=$exitCode)',
      );
    }
    if (!sawEvent) {
      throw const UrlImportDownloaderException('ダウンローダーから進捗応答を受け取れませんでした');
    }

    return LocalUrlDownloadResult(
      importedCount: importedCount,
      skippedCount: skippedCount,
      failedCount: failedCount,
      logLines: logLines,
      hitomiMetadataByRelativePath: hitomiMetadataByRelativePath,
    );
  }

  // ignore: unused_element
  Future<LocalUrlDownloadResult> _runDirectUrlDownload({
    required String sourceUrl,
    required String destinationFolder,
    required UrlImportOptions options,
    void Function(MediaTransferProgress progress)? onProgress,
  }) async {
    if (options.hasFavoriteTargets) {
      throw const UrlImportDownloaderException(
        'この環境のスタンドアロン URL 取り込みでは favorites 取得は未対応です。'
        '直接メディア URL を入力してください。',
      );
    }

    final prepared = await _prepareImportSources(sourceUrl, options);
    final urls = <String>[...prepared.directUrls, ...prepared.launcherUrls];
    final metadataByUrl = <String, HitomiGalleryMetadata>{
      ...prepared.metadataByDirectUrl,
    };
    if (urls.isEmpty) {
      throw const UrlImportDownloaderException('直接ダウンロードできる URL が見つかりませんでした');
    }

    final destinationDir = Directory(destinationFolder);
    if (!await destinationDir.exists()) {
      await destinationDir.create(recursive: true);
    }

    final client = HttpClient()..connectionTimeout = const Duration(minutes: 2);
    final logLines = <String>[];
    var importedCount = 0;
    var skippedCount = 0;
    var failedCount = 0;
    final hitomiMetadataByRelativePath = <String, HitomiGalleryMetadata>{};

    void appendLog(String line) {
      logLines.add(line);
      while (logLines.length > 80) {
        logLines.removeAt(0);
      }
    }

    try {
      for (var index = 0; index < urls.length; index++) {
        final rawUrl = urls[index];
        final uri = Uri.tryParse(rawUrl);
        if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
          failedCount++;
          appendLog('[skip] unsupported url: $rawUrl');
          continue;
        }

        onProgress?.call(
          MediaTransferProgress(
            sentBytes: index,
            totalBytes: urls.length,
            completedFiles: importedCount + skippedCount + failedCount,
            totalFiles: urls.length,
            currentFileName: rawUrl,
            /*
            statusLabel: 'URL からダウンロードしています',
            */
            statusLabel: 'URL からダウンロードしています',
          ),
        );

        HttpClientRequest request;
        try {
          request = await client.getUrl(uri);
        } on Exception catch (error) {
          failedCount++;
          appendLog('[error] open failed: $rawUrl ($error)');
          continue;
        }

        request.followRedirects = true;
        request.headers.set(HttpHeaders.userAgentHeader, _standaloneUserAgent);
        request.headers.set(HttpHeaders.acceptHeader, _mediaAcceptHeader);

        HttpClientResponse response;
        try {
          response = await request.close();
        } on Exception catch (error) {
          failedCount++;
          appendLog('[error] request failed: $rawUrl ($error)');
          continue;
        }

        if (response.statusCode < 200 || response.statusCode >= 300) {
          failedCount++;
          appendLog('[error] http ${response.statusCode}: $rawUrl');
          await response.drain<void>();
          continue;
        }

        String fileName;
        final importMetadata = metadataByUrl[rawUrl];
        try {
          fileName = _buildDownloadFileName(
            uri,
            response,
            sequence: importedCount + skippedCount + failedCount + 1,
            metadata: importMetadata,
          );
        } on UrlImportDownloaderException catch (error) {
          failedCount++;
          appendLog('[error] ${error.message}: $rawUrl');
          await response.drain<void>();
          continue;
        }

        final targetPath = p.join(destinationDir.path, fileName);
        final targetFile = File(targetPath);
        final relativeKey = HitomiGalleryMetadata.normalizeRelativePathKey(
          fileName,
        );
        if (relativeKey != null && importMetadata != null) {
          hitomiMetadataByRelativePath[relativeKey] = importMetadata;
        }
        if (await targetFile.exists() && !options.overwriteExistingFiles) {
          skippedCount++;
          appendLog('[skip] exists: $fileName');
          await response.drain<void>();
          continue;
        }

        IOSink? sink;
        try {
          sink = await _writeResponseToMediaFile(response, targetFile);
          importedCount++;
          appendLog('[ok] $rawUrl -> $fileName');
        } on Exception catch (error) {
          failedCount++;
          appendLog('[error] write failed: $fileName ($error)');
          try {
            await sink?.close();
          } catch (_) {}
          if (await targetFile.exists()) {
            try {
              await targetFile.delete();
            } catch (_) {}
          }
        }

        final completed = importedCount + skippedCount + failedCount;
        onProgress?.call(
          MediaTransferProgress(
            sentBytes: completed,
            totalBytes: urls.length,
            completedFiles: completed,
            totalFiles: urls.length,
            currentFileName: fileName,
            /*
            statusLabel: 'URL ダウンロードを処理しています',
            */
            statusLabel: 'URL ダウンロードを処理しています',
          ),
        );
      }
    } finally {
      client.close(force: true);
    }

    return LocalUrlDownloadResult(
      importedCount: importedCount,
      skippedCount: skippedCount,
      failedCount: failedCount,
      logLines: logLines,
      hitomiMetadataByRelativePath: hitomiMetadataByRelativePath,
    );
  }

  Future<LocalUrlDownloadResult> _runDirectUrlDownloadUrls({
    required List<String> urls,
    required String destinationFolder,
    required UrlImportOptions options,
    Map<String, HitomiGalleryMetadata> metadataByUrl =
        const <String, HitomiGalleryMetadata>{},
    void Function(MediaTransferProgress progress)? onProgress,
  }) async {
    if (options.hasFavoriteTargets) {
      throw const UrlImportDownloaderException(
        'この環境のスタンドアロン URL 取り込みでは favorites 取得は未対応です。'
        '直接メディア URL を入力してください。',
      );
    }
    if (urls.isEmpty) {
      throw const UrlImportDownloaderException('直接ダウンロードできる URL が見つかりませんでした');
    }

    final destinationDir = Directory(destinationFolder);
    if (!await destinationDir.exists()) {
      await destinationDir.create(recursive: true);
    }

    final client = HttpClient()..connectionTimeout = const Duration(minutes: 2);
    final logLines = <String>[];
    var importedCount = 0;
    var skippedCount = 0;
    var failedCount = 0;
    final hitomiMetadataByRelativePath = <String, HitomiGalleryMetadata>{};

    void appendLog(String line) {
      logLines.add(line);
      while (logLines.length > 80) {
        logLines.removeAt(0);
      }
    }

    try {
      for (var index = 0; index < urls.length; index++) {
        final rawUrl = urls[index];
        final uri = Uri.tryParse(rawUrl);
        if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
          failedCount++;
          appendLog('[skip] unsupported url: $rawUrl');
          continue;
        }

        onProgress?.call(
          MediaTransferProgress(
            sentBytes: index,
            totalBytes: urls.length,
            completedFiles: importedCount + skippedCount + failedCount,
            totalFiles: urls.length,
            currentFileName: rawUrl,
            statusLabel: 'URL からダウンロードしています',
          ),
        );

        HttpClientRequest request;
        try {
          request = await client.getUrl(uri);
        } on Exception catch (error) {
          failedCount++;
          appendLog('[error] open failed: $rawUrl ($error)');
          continue;
        }

        request.followRedirects = true;
        request.headers.set(HttpHeaders.userAgentHeader, _standaloneUserAgent);
        request.headers.set(HttpHeaders.acceptHeader, _mediaAcceptHeader);

        HttpClientResponse response;
        try {
          response = await request.close();
        } on Exception catch (error) {
          failedCount++;
          appendLog('[error] request failed: $rawUrl ($error)');
          continue;
        }

        if (response.statusCode < 200 || response.statusCode >= 300) {
          failedCount++;
          appendLog('[error] http ${response.statusCode}: $rawUrl');
          await response.drain<void>();
          continue;
        }

        String fileName;
        final importMetadata = metadataByUrl[rawUrl];
        try {
          fileName = _buildDownloadFileName(
            uri,
            response,
            sequence: importedCount + skippedCount + failedCount + 1,
            metadata: importMetadata,
          );
        } on UrlImportDownloaderException catch (error) {
          failedCount++;
          appendLog('[error] ${error.message}: $rawUrl');
          await response.drain<void>();
          continue;
        }

        final targetPath = p.join(destinationDir.path, fileName);
        final targetFile = File(targetPath);
        final relativeKey = HitomiGalleryMetadata.normalizeRelativePathKey(
          fileName,
        );
        if (relativeKey != null && importMetadata != null) {
          hitomiMetadataByRelativePath[relativeKey] = importMetadata;
        }
        if (await targetFile.exists() && !options.overwriteExistingFiles) {
          skippedCount++;
          appendLog('[skip] exists: $fileName');
          await response.drain<void>();
          continue;
        }

        IOSink? sink;
        try {
          sink = await _writeResponseToMediaFile(response, targetFile);
          importedCount++;
          appendLog('[ok] $rawUrl -> $fileName');
        } on Exception catch (error) {
          failedCount++;
          appendLog('[error] write failed: $fileName ($error)');
          try {
            await sink?.close();
          } catch (_) {}
          if (await targetFile.exists()) {
            try {
              await targetFile.delete();
            } catch (_) {}
          }
        }

        final completed = importedCount + skippedCount + failedCount;
        onProgress?.call(
          MediaTransferProgress(
            sentBytes: completed,
            totalBytes: urls.length,
            completedFiles: completed,
            totalFiles: urls.length,
            currentFileName: fileName,
            statusLabel: 'URL ダウンロードを処理しています',
          ),
        );
      }
    } finally {
      client.close(force: true);
    }

    return LocalUrlDownloadResult(
      importedCount: importedCount,
      skippedCount: skippedCount,
      failedCount: failedCount,
      logLines: logLines,
      hitomiMetadataByRelativePath: hitomiMetadataByRelativePath,
    );
  }

  Future<List<String>> _collectInputUrls(
    String sourceUrl,
    UrlImportOptions options,
  ) async {
    final urls = <String>[];
    final seen = <String>{};

    void addUrl(String raw) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) {
        return;
      }
      if (seen.add(trimmed)) {
        urls.add(trimmed);
      }
    }

    for (final url in options.collectSourceUrls(sourceUrl)) {
      addUrl(url);
    }

    final urlListFilePath = options.normalizedUrlListFilePath;
    if (urlListFilePath != null) {
      final file = File(urlListFilePath);
      if (!await file.exists()) {
        throw UrlImportDownloaderException(
          'URL 一覧ファイルを開けませんでした: $urlListFilePath',
        );
      }
      final content = await file.readAsString();
      for (final line in const LineSplitter().convert(content)) {
        addUrl(line);
      }
    }

    return urls;
  }

  Future<_ResolvedDirectUrl?> _resolveSpecialDirectUrl(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return null;
    }

    final host = uri.host.toLowerCase();
    if (host == _dddSmartCdnHost && uri.path.toLowerCase().endsWith('.pdf')) {
      return _ResolvedDirectUrl(url: uri.toString());
    }
    if (host != _dddSmartHost) {
      return null;
    }

    final fileName = uri.pathSegments.isEmpty
        ? ''
        : uri.pathSegments.last.toLowerCase();
    if (fileName == 'show-m.php') {
      return _resolveDddSmartPdfUrlFromShowPage(uri);
    }
    if (fileName.startsWith('dl-')) {
      final resolvedUrl = await _resolveDddSmartPdfUrlFromDownloadPage(uri);
      return _ResolvedDirectUrl(url: resolvedUrl);
    }

    return null;
  }

  Future<_ResolvedDirectUrl> _resolveDddSmartPdfUrlFromShowPage(
    Uri showPageUri,
  ) async {
    final html = await _downloadHtml(showPageUri);
    final dlHref =
        _extractAnchorHrefByLabel(html, 'DL\u30da\u30fc\u30b8') ??
        _extractFirstDddSmartDownloadPageHref(html);
    if (dlHref == null) {
      throw UrlImportDownloaderException(
        'ddd-smart DL page link was not found: $showPageUri',
      );
    }
    final resolvedUrl = await _resolveDddSmartPdfUrlFromDownloadPage(
      showPageUri.resolve(dlHref),
    );
    return _ResolvedDirectUrl(
      url: resolvedUrl,
      metadata: _extractDddSmartMetadataFromShowPage(html, showPageUri),
    );
  }

  Future<String> _resolveDddSmartPdfUrlFromDownloadPage(
    Uri downloadPageUri,
  ) async {
    final html = await _downloadHtml(downloadPageUri);
    final pdfHref =
        _extractAnchorHrefByLabel(
          html,
          'PDF\u30c0\u30a6\u30f3\u30ed\u30fc\u30c9',
        ) ??
        _extractFirstPdfHref(html);
    if (pdfHref == null) {
      throw UrlImportDownloaderException(
        'ddd-smart PDF link was not found: $downloadPageUri',
      );
    }
    return downloadPageUri.resolve(pdfHref).toString();
  }

  HitomiGalleryMetadata _extractDddSmartMetadataFromShowPage(
    String html,
    Uri showPageUri,
  ) {
    final scopedHtml = _extractDddSmartMetadataScope(html);
    final title = _extractDddSmartTitle(scopedHtml);
    final circles = _extractDddSmartKeywordsFromSection(
      scopedHtml,
      sectionLabels: const <String>['\u30b5\u30fc\u30af\u30eb'],
      expectedType: '3',
    );
    return HitomiGalleryMetadata(
      artists: circles,
      groups: circles,
      series: _extractDddSmartKeywordsFromSection(
        scopedHtml,
        sectionLabels: const <String>['\u539f\u4f5c'],
        expectedType: '1',
      ),
      characters: _extractDddSmartKeywordsFromSection(
        scopedHtml,
        sectionLabels: const <String>['\u30ad\u30e3\u30e9\u30af\u30bf\u30fc'],
        expectedType: '2',
      ),
      tags: _extractDddSmartKeywordsFromSection(
        scopedHtml,
        sectionLabels: const <String>['\u30bf\u30b0'],
        expectedType: '4',
      ),
      title: title,
      japaneseTitle: title,
      mediaType: 'ddd-smart',
      sourceUrl: showPageUri.toString(),
      readerUrl: showPageUri.toString(),
    );
  }

  String _extractDddSmartMetadataScope(String html) {
    const markers = <String>[
      'DL\u30da\u30fc\u30b8',
      '\u4e00\u89a7\u8aad\u307f',
      'PDF\u30c0\u30a6\u30f3\u30ed\u30fc\u30c9',
    ];
    for (final marker in markers) {
      final index = html.indexOf(marker);
      if (index < 0) {
        continue;
      }
      final start = index > 20000 ? index - 20000 : 0;
      final end = index + 20000 < html.length ? index + 20000 : html.length;
      return html.substring(start, end);
    }
    return html;
  }

  String? _extractDddSmartTitle(String html) {
    final patterns = <RegExp>[
      RegExp(r'<h1\b[^>]*>(.*?)</h1>', caseSensitive: false, dotAll: true),
      RegExp(
        r'''<h2\b[^>]*class\s*=\s*(?:"[^"]*\bcard-panel\b[^"]*"|'[^']*\bcard-panel\b[^']*')[^>]*>(.*?)</h2>''',
        caseSensitive: false,
        dotAll: true,
      ),
      RegExp(
        r'''<div\b[^>]*class\s*=\s*(?:"[^"]*\bcard-panel\b[^"]*"|'[^']*\bcard-panel\b[^']*')[^>]*>(.*?)</div>''',
        caseSensitive: false,
        dotAll: true,
      ),
      RegExp(r'<title>(.*?)</title>', caseSensitive: false, dotAll: true),
    ];
    for (final pattern in patterns) {
      for (final match in pattern.allMatches(html)) {
        final text = _normalizeHtmlText(match.group(1) ?? '');
        if (_looksLikeDddSmartTitle(text)) {
          return text;
        }
      }
    }
    return null;
  }

  bool _looksLikeDddSmartTitle(String text) {
    final normalized = text.trim();
    if (normalized.isEmpty || normalized.length < 4) {
      return false;
    }

    const blockedExact = <String>{
      '\u539f\u4f5c',
      '\u30ad\u30e3\u30e9',
      '\u30ad\u30e3\u30e9\u30af\u30bf\u30fc',
      '\u30b5\u30fc\u30af\u30eb',
      '\u30bf\u30b0',
      '\u66f4\u65b0\u65e5',
      '\u767a\u884c\u65e5',
      '\u30aa\u30b9\u30b9\u30e1\u5ea6',
      '\u4e00\u89a7\u8aad\u307f',
      'DL\u30da\u30fc\u30b8',
      'PDF\u30c0\u30a6\u30f3\u30ed\u30fc\u30c9',
    };
    if (blockedExact.contains(normalized)) {
      return false;
    }

    return !normalized.contains('\u540c\u4eba\u3059\u307e\u30fc\u3068') &&
        !normalized.contains('ddd-smart') &&
        !normalized.contains('\u304b\u3089\u63a2\u3059') &&
        !normalized.contains('\u4e00\u89a7') &&
        !normalized.contains('\u30e9\u30f3\u30ad\u30f3\u30b0');
  }

  List<String> _extractDddSmartKeywordsFromSection(
    String html, {
    required List<String> sectionLabels,
    required String expectedType,
  }) {
    final sectionHtml = _extractDddSmartSectionHtml(
      html,
      sectionLabels: sectionLabels,
    );
    if (sectionHtml == null) {
      return const <String>[];
    }
    return _extractDddSmartKeywordsByType(
      sectionHtml,
      expectedType: expectedType,
    );
  }

  String? _extractDddSmartSectionHtml(
    String html, {
    required List<String> sectionLabels,
  }) {
    var start = -1;
    for (final label in sectionLabels) {
      final index = html.indexOf(label);
      if (index >= 0 && (start < 0 || index < start)) {
        start = index;
      }
    }
    if (start < 0) {
      return null;
    }

    const boundaryLabels = <String>[
      '\u539f\u4f5c',
      '\u30ad\u30e3\u30e9',
      '\u30ad\u30e3\u30e9\u30af\u30bf\u30fc',
      '\u30b5\u30fc\u30af\u30eb',
      '\u30bf\u30b0',
      '\u66f4\u65b0\u65e5',
      '\u767a\u884c\u65e5',
      '\u30aa\u30b9\u30b9\u30e1\u5ea6',
      '\u4e00\u89a7\u8aad\u307f',
      'DL\u30da\u30fc\u30b8',
    ];
    var end = html.length;
    for (final label in boundaryLabels) {
      if (sectionLabels.contains(label)) {
        continue;
      }
      final index = html.indexOf(label, start + 1);
      if (index >= 0 && index < end) {
        end = index;
      }
    }

    final maxEnd = start + 4000;
    if (end > maxEnd) {
      end = maxEnd < html.length ? maxEnd : html.length;
    }
    if (end <= start) {
      return null;
    }
    return html.substring(start, end);
  }

  List<String> _extractDddSmartKeywordsByType(
    String html, {
    required String expectedType,
  }) {
    final out = <String>[];
    final seen = <String>{};
    final anchorPattern = RegExp(
      r"""<a\b[^>]*href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>(.*?)</a>""",
      caseSensitive: false,
      dotAll: true,
    );
    for (final match in anchorPattern.allMatches(html)) {
      final href = _decodeHtmlEntities(
        (match.group(1) ?? match.group(2) ?? match.group(3) ?? '').trim(),
      );
      final keyword = _extractDddSmartKeywordFromHref(
        href,
        expectedType: expectedType,
      );
      if (keyword == null) {
        continue;
      }
      final lowered = keyword.toLowerCase();
      if (seen.add(lowered)) {
        out.add(keyword);
      }
    }
    return out;
  }

  String? _extractDddSmartKeywordFromHref(
    String href, {
    required String expectedType,
  }) {
    if (href.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(href);
    if (uri == null || uri.path.isEmpty) {
      return null;
    }
    final type = uri.queryParameters['type']?.trim();
    final keyword = uri.queryParameters['keyword']?.trim();
    if (type != expectedType || keyword == null || keyword.isEmpty) {
      return null;
    }
    return keyword;
  }

  String? _extractFirstDddSmartDownloadPageHref(String html) {
    final dlHrefPattern = RegExp(
      r'''href\s*=\s*(?:"([^"]*\/dl-[^"]+)"|'([^']*\/dl-[^']+)'|([^\s>]*\/dl-[^\s>]+))''',
      caseSensitive: false,
      dotAll: true,
    );
    final match = dlHrefPattern.firstMatch(html);
    final href = (match?.group(1) ?? match?.group(2) ?? match?.group(3) ?? '')
        .trim();
    if (href.isEmpty) {
      return null;
    }
    return _decodeHtmlEntities(href);
  }

  Future<Uint8List> _downloadBytes(Uri uri, {String accept = '*/*'}) async {
    final client = HttpClient()..connectionTimeout = const Duration(minutes: 2);
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = true;
      request.headers.set(HttpHeaders.userAgentHeader, _standaloneUserAgent);
      request.headers.set(HttpHeaders.acceptHeader, accept);
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        throw UrlImportDownloaderException(
          'HTTP ${response.statusCode} while resolving $uri',
        );
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } on UrlImportDownloaderException {
      rethrow;
    } on Exception catch (error) {
      throw UrlImportDownloaderException('URL resolving failed: $uri ($error)');
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _downloadHtml(Uri uri) async {
    try {
      final bytes = await _downloadBytes(
        uri,
        accept:
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      );
      return const Utf8Decoder(allowMalformed: true).convert(bytes);
    } on UrlImportDownloaderException {
      rethrow;
    }
  }

  String? _extractAnchorHrefByLabel(String html, String label) {
    final anchorPattern = RegExp(
      r"""<a\b[^>]*href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>(.*?)</a>""",
      caseSensitive: false,
      dotAll: true,
    );
    for (final match in anchorPattern.allMatches(html)) {
      final href = (match.group(1) ?? match.group(2) ?? match.group(3) ?? '')
          .trim();
      if (href.isEmpty) {
        continue;
      }
      final anchorText = _normalizeHtmlText(match.group(4) ?? '');
      if (anchorText.contains(label)) {
        return _decodeHtmlEntities(href);
      }
    }
    return null;
  }

  String? _extractFirstPdfHref(String html) {
    final pdfHrefPattern = RegExp(
      r'''href\s*=\s*(?:"([^"]+\.pdf[^"]*)"|'([^']+\.pdf[^']*)'|([^\s>]+\.pdf[^\s>]*))''',
      caseSensitive: false,
      dotAll: true,
    );
    final match = pdfHrefPattern.firstMatch(html);
    final href = (match?.group(1) ?? match?.group(2) ?? match?.group(3) ?? '')
        .trim();
    if (href.isEmpty) {
      return null;
    }
    return _decodeHtmlEntities(href);
  }

  String _normalizeHtmlText(String rawHtml) {
    final withoutTags = rawHtml.replaceAll(RegExp(r'<[^>]+>'), ' ');
    final decoded = _decodeHtmlEntities(withoutTags);
    return decoded.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _decodeHtmlEntities(String input) {
    return input.replaceAllMapped(RegExp(r'&(#x?[0-9a-fA-F]+|[a-zA-Z]+);'), (
      match,
    ) {
      final token = (match.group(1) ?? '').toLowerCase();
      switch (token) {
        case 'amp':
          return '&';
        case 'lt':
          return '<';
        case 'gt':
          return '>';
        case 'quot':
          return '"';
        case 'apos':
          return "'";
        case 'nbsp':
          return ' ';
      }
      if (token.startsWith('#x')) {
        final value = int.tryParse(token.substring(2), radix: 16);
        return value == null ? match.group(0)! : String.fromCharCode(value);
      }
      if (token.startsWith('#')) {
        final value = int.tryParse(token.substring(1));
        return value == null ? match.group(0)! : String.fromCharCode(value);
      }
      return match.group(0)!;
    });
  }

  bool _supportsLauncherUrl(String rawUrl) {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return false;
    }

    final host = uri.host.toLowerCase();
    if (RegExp(r'^(?:kemono|coomer)\.(?:party|su|cr|st)$').hasMatch(host)) {
      final segments = uri.pathSegments;
      if (segments.length >= 3 &&
          segments[0].isNotEmpty &&
          segments[1].toLowerCase() == 'user' &&
          segments[2].isNotEmpty) {
        return true;
      }
    }

    if (host == 'hitomi.la' && uri.pathSegments.isNotEmpty) {
      return _launcherSupportedHitomiSegments.contains(
        uri.pathSegments.first.toLowerCase(),
      );
    }

    return false;
  }

  UrlImportOptions _copyOptionsWithoutUrlListFile(UrlImportOptions options) {
    return UrlImportOptions(
      cookieMode: options.cookieMode,
      cookieFilePath: options.cookieFilePath,
      favoriteSites: options.favoriteSites,
      favoritePosts: options.favoritePosts,
      favoriteUserServices: options.favoriteUserServices,
      mediaType: options.mediaType,
      parallelDownloads: options.parallelDownloads,
      includeInlineImages: options.includeInlineImages,
      includePostContent: options.includePostContent,
      includeComments: options.includeComments,
      saveJson: options.saveJson,
      overwriteExistingFiles: options.overwriteExistingFiles,
      verbose: options.verbose,
      convertHitomiToPdf: options.convertHitomiToPdf,
      preferHitomiOriginal: options.preferHitomiOriginal,
    );
  }

  UrlImportOptions _copyOptionsForDirectDownload(UrlImportOptions options) {
    return UrlImportOptions(
      cookieMode: options.cookieMode,
      cookieFilePath: options.cookieFilePath,
      favoriteSites: options.favoriteSites,
      mediaType: options.mediaType,
      parallelDownloads: options.parallelDownloads,
      includeInlineImages: options.includeInlineImages,
      includePostContent: options.includePostContent,
      includeComments: options.includeComments,
      saveJson: options.saveJson,
      overwriteExistingFiles: options.overwriteExistingFiles,
      verbose: options.verbose,
      convertHitomiToPdf: options.convertHitomiToPdf,
      preferHitomiOriginal: options.preferHitomiOriginal,
    );
  }

  void Function(MediaTransferProgress progress)? _withProgressOffset(
    void Function(MediaTransferProgress progress)? onProgress, {
    required int completedOffset,
    required int trailingFiles,
  }) {
    if (onProgress == null) {
      return null;
    }

    return (progress) {
      final totalFiles = progress.totalFiles > 0
          ? completedOffset + progress.totalFiles + trailingFiles
          : completedOffset + trailingFiles;
      final completedFiles = completedOffset + progress.completedFiles;
      onProgress(
        MediaTransferProgress(
          sentBytes: completedFiles,
          totalBytes: totalFiles,
          completedFiles: completedFiles,
          totalFiles: totalFiles,
          currentFileName: progress.currentFileName,
          statusLabel: progress.statusLabel,
        ),
      );
    };
  }

  int _totalHandledFiles(List<LocalUrlDownloadResult> results) {
    return results.fold<int>(
      0,
      (sum, result) =>
          sum + result.importedCount + result.skippedCount + result.failedCount,
    );
  }

  LocalUrlDownloadResult _mergeDownloadResults(
    List<LocalUrlDownloadResult> results,
  ) {
    if (results.isEmpty) {
      return const LocalUrlDownloadResult(importedCount: 0);
    }
    if (results.length == 1) {
      return results.single;
    }

    final logLines = <String>[];
    final hitomiMetadataByRelativePath = <String, HitomiGalleryMetadata>{};
    var importedCount = 0;
    var skippedCount = 0;
    var failedCount = 0;

    for (final result in results) {
      importedCount += result.importedCount;
      skippedCount += result.skippedCount;
      failedCount += result.failedCount;
      logLines.addAll(result.logLines);
      while (logLines.length > 80) {
        logLines.removeAt(0);
      }
      hitomiMetadataByRelativePath.addAll(result.hitomiMetadataByRelativePath);
    }

    return LocalUrlDownloadResult(
      importedCount: importedCount,
      skippedCount: skippedCount,
      failedCount: failedCount,
      logLines: logLines,
      hitomiMetadataByRelativePath: hitomiMetadataByRelativePath,
    );
  }

  Future<IOSink> _writeResponseToMediaFile(
    HttpClientResponse response,
    File targetFile,
  ) async {
    final sink = targetFile.openWrite();
    await response.forEach(sink.add);
    await sink.flush();
    await sink.close();
    await _validateSavedMediaFile(targetFile);
    return sink;
  }

  Future<void> _validateSavedMediaFile(File file) async {
    if (MediaFileTypes.extensionOf(file.path).toLowerCase() != '.pdf') {
      return;
    }
    if (!await _hasPdfHeader(file)) {
      throw const UrlImportDownloaderException('PDF として読み込めない内容です');
    }
  }

  Future<bool> _hasPdfHeader(File file) async {
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file || stat.size < 5) {
      return false;
    }
    final raf = await file.open();
    try {
      final headerLength = stat.size < 1024 ? stat.size : 1024;
      final header = await raf.read(headerLength);
      return _containsBytes(header, const <int>[0x25, 0x50, 0x44, 0x46, 0x2D]);
    } finally {
      await raf.close();
    }
  }

  bool _containsBytes(List<int> bytes, List<int> pattern) {
    if (pattern.isEmpty || bytes.length < pattern.length) {
      return false;
    }
    for (var index = 0; index <= bytes.length - pattern.length; index++) {
      var matches = true;
      for (var offset = 0; offset < pattern.length; offset++) {
        if (bytes[index + offset] != pattern[offset]) {
          matches = false;
          break;
        }
      }
      if (matches) {
        return true;
      }
    }
    return false;
  }

  String _buildDownloadFileName(
    Uri uri,
    HttpClientResponse response, {
    required int sequence,
    HitomiGalleryMetadata? metadata,
  }) {
    final disposition = response.headers.value(_contentDispositionHeader);
    final fromDisposition = _decodeContentDispositionFileName(disposition);
    final fromUrl = uri.pathSegments.isNotEmpty
        ? Uri.decodeComponent(uri.pathSegments.last)
        : '';
    final preferred = (fromDisposition ?? fromUrl).trim();
    final inferredExtension = _extensionFromContentType(
      response.headers.contentType,
    );

    var fileName = _sanitizeFileName(preferred);
    final preferredExtension = MediaFileTypes.extensionOf(
      fileName ?? preferred,
    );
    final titleFallbackExtension = preferredExtension.isNotEmpty
        ? preferredExtension
        : inferredExtension;
    if (_shouldReplaceGenericDownloadFileName(fileName)) {
      fileName =
          _buildTitleBasedFileName(
            metadata,
            preferredExtension: titleFallbackExtension,
          ) ??
          fileName;
    }
    fileName ??=
        _buildTitleBasedFileName(
          metadata,
          preferredExtension: inferredExtension,
        ) ??
        'download_$sequence${inferredExtension ?? ''}';

    final currentExtension = MediaFileTypes.extensionOf(fileName);
    if (currentExtension.isEmpty && inferredExtension != null) {
      fileName = '$fileName$inferredExtension';
    } else if (!MediaFileTypes.isSupportedMediaFileName(fileName) &&
        inferredExtension != null &&
        MediaFileTypes.mediaExtensions.contains(inferredExtension)) {
      final base = p.basenameWithoutExtension(fileName);
      fileName = '$base$inferredExtension';
    }

    if (!MediaFileTypes.isSupportedMediaFileName(fileName)) {
      throw UrlImportDownloaderException('対応していないメディア URL です');
    }
    return fileName;
  }

  bool _shouldReplaceGenericDownloadFileName(String? fileName) {
    if (fileName == null) {
      return false;
    }
    final baseName = p.basenameWithoutExtension(fileName).trim().toLowerCase();
    return baseName == 'all';
  }

  String? _buildTitleBasedFileName(
    HitomiGalleryMetadata? metadata, {
    String? preferredExtension,
  }) {
    if (metadata == null) {
      return null;
    }
    final title =
        _trimmedOrNull(metadata.japaneseTitle) ??
        _trimmedOrNull(metadata.title) ??
        _trimmedOrNull(metadata.englishTitle);
    final sanitizedTitle = _sanitizeFileName(title ?? '');
    if (sanitizedTitle == null) {
      return null;
    }
    if (MediaFileTypes.extensionOf(sanitizedTitle).isNotEmpty) {
      return sanitizedTitle;
    }
    final extension = (preferredExtension ?? '').trim();
    if (extension.isEmpty) {
      return sanitizedTitle;
    }
    return '$sanitizedTitle$extension';
  }

  String? _sanitizeFileName(String raw) {
    var value = raw.trim();
    if (value.isEmpty) {
      return null;
    }
    value = value
        .replaceAll('\\', '/')
        .split('/')
        .last
        .replaceAll(RegExp(r'[<>:\"/\\|?*\x00-\x1F]+'), '_')
        .replaceAll(RegExp(r'[\r\n]+'), ' ')
        .trim();
    while (value.endsWith('.') || value.endsWith(' ')) {
      value = value.substring(0, value.length - 1).trimRight();
    }
    if (value.isEmpty || value == '.' || value == '..') {
      return null;
    }
    return value;
  }

  String? _decodeContentDispositionFileName(String? rawHeader) {
    final header = rawHeader?.trim();
    if (header == null || header.isEmpty) {
      return null;
    }

    final utf8Match = RegExp(
      r'''filename\*\s*=\s*(?:UTF-8'')?([^;]+)''',
      caseSensitive: false,
    ).firstMatch(header);
    if (utf8Match != null) {
      return Uri.decodeComponent(
        utf8Match.group(1)!.trim().replaceAll('"', ''),
      );
    }

    final plainMatch = RegExp(
      r'''filename\s*=\s*"([^"]+)"|filename\s*=\s*([^;]+)''',
      caseSensitive: false,
    ).firstMatch(header);
    if (plainMatch != null) {
      return (plainMatch.group(1) ?? plainMatch.group(2) ?? '')
          .trim()
          .replaceAll('"', '');
    }

    return null;
  }

  String? _extensionFromContentType(ContentType? contentType) {
    final mime = contentType?.mimeType.toLowerCase();
    switch (mime) {
      case 'application/pdf':
        return '.pdf';
      case 'image/jpeg':
      case 'image/jpg':
        return '.jpg';
      case 'image/png':
        return '.png';
      case 'image/gif':
        return '.gif';
      case 'image/webp':
        return '.webp';
      case 'image/bmp':
      case 'image/x-ms-bmp':
        return '.bmp';
      case 'image/avif':
        return '.avif';
      default:
        return null;
    }
  }

  int _asInt(Object? value, int fallback) {
    if (value is int) {
      return value;
    }
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  bool _looksLikeMissingLauncher(String message) {
    final lower = message.toLowerCase();
    return lower.contains('not found') ||
        lower.contains('is not recognized') ||
        lower.contains('no such file');
  }

  List<String> _buildTaskArgs(String sourceUrl, UrlImportOptions options) {
    final args = <String>[];

    for (final url in options.collectSourceUrls(sourceUrl)) {
      args
        ..add('--url')
        ..add(url);
    }

    final cookieFilePath = options.normalizedCookieFilePath;
    if (cookieFilePath != null) {
      args
        ..add('--cookies')
        ..add(cookieFilePath);
    }

    args
      ..add('--cookie-mode')
      ..add(options.cookieMode.apiValue);

    final urlListFilePath = options.normalizedUrlListFilePath;
    if (urlListFilePath != null) {
      args
        ..add('--from-file')
        ..add(urlListFilePath);
    }

    final sites = options.normalizedFavoriteSites;
    if (sites.isNotEmpty) {
      args
        ..add('--sites')
        ..add(sites.join(','));
    }
    if (options.favoritePosts) {
      args.add('--fav-posts');
    }

    final favoriteUserServices = options.normalizedFavoriteUserServices;
    if (favoriteUserServices.isNotEmpty) {
      args
        ..add('--fav-users')
        ..add(favoriteUserServices.join(','));
    }

    args
      ..add('--media-type')
      ..add(options.mediaType.apiValue)
      ..add('--parallel-downloads')
      ..add('${options.effectiveParallelDownloads}');

    if (options.includeInlineImages) {
      args.add('--inline');
    }
    if (options.includePostContent) {
      args.add('--content');
    }
    if (options.includeComments) {
      args.add('--comments');
    }
    if (options.saveJson) {
      args.add('--json');
    }
    if (options.overwriteExistingFiles) {
      args.add('--overwrite');
    }
    if (options.verbose) {
      args.add('--verbose');
    }
    if (options.convertHitomiToPdf) {
      args.add('--hitomi-pdf');
    }
    if (options.preferHitomiOriginal) {
      args.add('--hitomi-original');
    }

    return args;
  }

  void _storeHitomiMetadataEvent(
    Map<String, dynamic> event, {
    required String destinationFolder,
    required Map<String, HitomiGalleryMetadata> out,
  }) {
    final type = event['type']?.toString().trim().toLowerCase();
    if (type != 'hitomi_metadata') {
      return;
    }

    final pdfPath = event['pdf_path']?.toString();
    final relativePath = _relativePathFromAbsolute(
      pdfPath,
      rootFolder: destinationFolder,
    );
    final key = HitomiGalleryMetadata.normalizeRelativePathKey(relativePath);
    if (key == null) {
      return;
    }

    out[key] = HitomiGalleryMetadata(
      artists: _stringListFromEvent(event['artists']),
      groups: _stringListFromEvent(event['groups']),
      series: _stringListFromEvent(event['series']),
      characters: _stringListFromEvent(event['characters']),
      tags: _stringListFromEvent(event['tags']),
      title: _trimmedOrNull(event['title']),
      englishTitle: _trimmedOrNull(event['english_title']),
      japaneseTitle: _trimmedOrNull(event['japanese_title']),
      mediaType: _trimmedOrNull(event['media_type']),
      language: _trimmedOrNull(event['language']),
      sourceUrl: _trimmedOrNull(event['source_url']),
      readerUrl: _trimmedOrNull(event['reader_url']),
    );
  }

  String? _relativePathFromAbsolute(
    String? rawPath, {
    required String rootFolder,
  }) {
    final trimmedPath = rawPath?.trim() ?? '';
    final trimmedRoot = rootFolder.trim();
    if (trimmedPath.isEmpty || trimmedRoot.isEmpty) {
      return null;
    }

    final normalizedPath = p.normalize(trimmedPath);
    final normalizedRoot = p.normalize(trimmedRoot);
    if (normalizedPath == normalizedRoot ||
        !p.isWithin(normalizedRoot, normalizedPath)) {
      return null;
    }
    return p
        .relative(normalizedPath, from: normalizedRoot)
        .replaceAll('\\', '/');
  }

  List<String> _stringListFromEvent(Object? value) {
    if (value is! List) {
      return const <String>[];
    }
    return value
        .map((entry) => entry.toString().trim())
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false);
  }

  String? _trimmedOrNull(Object? value) {
    final trimmed = value?.toString().trim() ?? '';
    if (trimmed.isEmpty) {
      return null;
    }
    return trimmed;
  }
}

List<List<T>> _chunkItems<T>(List<T> items, int chunkSize) {
  final normalizedSize = chunkSize < 1 ? 1 : chunkSize;
  final chunks = <List<T>>[];
  for (var index = 0; index < items.length; index += normalizedSize) {
    final end = index + normalizedSize;
    chunks.add(items.sublist(index, end > items.length ? items.length : end));
  }
  return chunks;
}
