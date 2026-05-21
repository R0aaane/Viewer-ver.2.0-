import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/storage_keys.dart';
import '../domain/models/creator_search_target.dart';

class CreatorSiteResolverService {
  CreatorSiteResolverService(this._dio);

  static const List<String> _kemonoOrigins = [
    'https://kemono.cr',
  ];

  final Dio _dio;
  final Map<String, Future<List<CreatorSearchMatch>>> _cache = {};
  final Map<String, Future<Object?>> _kemonoCreatorListCache = {};
  final Set<String> _unreachableHosts = {};
  final Set<String> _disabledKemonoApiUrls = {};

  Future<List<CreatorSearchMatch>> resolve({
    required String authorName,
    required String authorUsername,
    bool allowNetwork = true,
    bool refresh = false,
  }) {
    final cacheKey =
        '${authorName.trim()}|${authorUsername.trim()}|network=$allowNetwork|refresh=$refresh';
    if (refresh) {
      _cache.remove(cacheKey);
    }
    return _cache.putIfAbsent(cacheKey, () {
      return _resolveUncached(
        authorName: authorName,
        authorUsername: authorUsername,
        allowNetwork: allowNetwork,
        refresh: refresh,
      );
    });
  }

  Future<List<CreatorSearchMatch>> _resolveUncached({
    required String authorName,
    required String authorUsername,
    required bool allowNetwork,
    required bool refresh,
  }) async {
    final authorNameCandidates = _buildAuthorNameCandidates(authorName);
    final usernameCandidates = _buildUsernameCandidates(authorUsername);
    if (authorNameCandidates.isEmpty && usernameCandidates.isEmpty) {
      return const <CreatorSearchMatch>[];
    }

    final persisted = await _loadPersistedMatches(authorUsername);
    final persistedTargets = refresh
        ? <CreatorSearchTarget>{}
        : persisted.map((match) => match.target).toSet();
    if (!allowNetwork) {
      return persisted;
    }

    final results = await Future.wait<CreatorSearchMatch?>([
      persistedTargets.contains(CreatorSearchTarget.hitomi)
          ? Future<CreatorSearchMatch?>.value(null)
          : _resolveWithFallback(
              _resolveHitomi,
              authorNameCandidates,
              usernameCandidates,
            ),
      persistedTargets.contains(CreatorSearchTarget.kemono)
          ? Future<CreatorSearchMatch?>.value(null)
          : _resolveWithFallback(
              _resolveKemono,
              authorNameCandidates,
              usernameCandidates,
            ),
      persistedTargets.contains(CreatorSearchTarget.dddSmart)
          ? Future<CreatorSearchMatch?>.value(null)
          : _resolveWithFallback(
              _resolveDddSmart,
              authorNameCandidates,
              usernameCandidates,
            ),
    ]);
    final matches = _mergeMatches(
      persisted,
      results.whereType<CreatorSearchMatch>(),
    );
    if (matches.isNotEmpty) {
      await _savePersistedMatches(
        authorUsername: authorUsername,
        matches: matches,
      );
    }
    return matches;
  }

  List<CreatorSearchMatch> _mergeMatches(
    Iterable<CreatorSearchMatch> existing,
    Iterable<CreatorSearchMatch> updates,
  ) {
    final byTarget = <CreatorSearchTarget, CreatorSearchMatch>{};
    for (final match in existing) {
      byTarget[match.target] = match;
    }
    for (final match in updates) {
      byTarget[match.target] = match;
    }
    return byTarget.values.toList(growable: false);
  }

  Future<CreatorSearchMatch?> _resolveHitomi(List<String> candidates) async {
    final romanCandidates = candidates
        .where((candidate) => RegExp(r'^[a-zA-Z0-9_. -]+$').hasMatch(candidate))
        .toList(growable: false);
    if (romanCandidates.isEmpty) {
      return null;
    }

    final pages = romanCandidates
        .map((candidate) => candidate.trim().toLowerCase())
        .where((candidate) => candidate.isNotEmpty)
        .map((candidate) => candidate[0])
        .map((first) => RegExp(r'[a-z]').hasMatch(first) ? first : '123')
        .toSet();

    for (final page in pages) {
      try {
        final response = await _dio.get<String>(
          'https://hitomi.la/allartists-$page.html',
          options: _plainOptions(),
        );
        final html = response.data ?? '';
        final match = _findBestHitomiMatch(html, romanCandidates);
        if (match != null) {
          return match;
        }
      } catch (error) {
        debugPrint('[xviewer][flutter] hitomi creator lookup failed: $error');
      }
    }
    return null;
  }

  Future<CreatorSearchMatch?> _resolveWithFallback(
    Future<CreatorSearchMatch?> Function(List<String> candidates) resolver,
    List<String> authorNameCandidates,
    List<String> usernameCandidates,
  ) async {
    final byName = authorNameCandidates.isEmpty
        ? null
        : await resolver(authorNameCandidates);
    if (byName != null) {
      return byName;
    }

    if (usernameCandidates.isEmpty) {
      return null;
    }
    return resolver(usernameCandidates);
  }

  CreatorSearchMatch? _findBestHitomiMatch(
    String html,
    List<String> candidates,
  ) {
    final artistPattern = RegExp(
      r'<a[^>]+href="([^"]*/artist/([^"]+)-all\.html)"[^>]*>(.*?)</a>',
      caseSensitive: false,
      dotAll: true,
    );
    CreatorSearchMatch? bestMatch;
    var bestScore = 0.0;

    for (final entry in artistPattern.allMatches(html)) {
      final label = _stripHtml(entry.group(3) ?? '');
      final normalizedLabel = _normalizeForMatch(label);
      if (normalizedLabel.isEmpty) {
        continue;
      }

      for (final candidate in candidates) {
        final score = _scoreMatch(normalizedLabel, _normalizeForMatch(candidate));
        if (score > bestScore) {
          bestScore = score;
          bestMatch = CreatorSearchMatch(
            target: CreatorSearchTarget.hitomi,
            title: label,
            url: CreatorSearchTarget.hitomi.buildUri(label).toString(),
          );
        }
      }
    }

    return bestScore >= 0.78 ? bestMatch : null;
  }

  Future<CreatorSearchMatch?> _resolveKemono(List<String> candidates) async {
    for (final candidate in candidates) {
      try {
        final uri = Uri.https(
          'kemono-api.mbaharip.com',
          '/kemono',
          {'keyword': candidate, 'itemsPerPage': '10'},
        );
        if (_disabledKemonoApiUrls.contains(uri.origin)) {
          continue;
        }
        final response = await _dio.get<String>(
          uri.toString(),
          options: _plainOptions(),
        );
        final match = _findBestKemonoApiMatch(
          jsonDecode(response.data ?? ''),
          candidates,
          'https://kemono.cr',
        );
        if (match != null) {
          return match;
        }
      } catch (error) {
        debugPrint(
          '[xviewer][flutter] kemono search API lookup failed: $error',
        );
        _rememberDisabledKemonoApi(error, 'https://kemono-api.mbaharip.com');
      }
    }

    for (final origin in _kemonoOrigins) {
      if (_isOriginUnreachable(origin)) {
        continue;
      }
      for (final endpoint in const [
        '/api/v1/creators',
        '/api/v1/creators.txt',
      ]) {
        try {
          final match = _findBestKemonoApiMatch(
            await _fetchKemonoCreatorList(origin, endpoint),
            candidates,
            origin,
          );
          if (match != null) {
            return match;
          }
        } catch (error) {
          debugPrint(
            '[xviewer][flutter] kemono creator API lookup failed: $error',
          );
        }
      }
    }

    for (final origin in _kemonoOrigins) {
      if (_isOriginUnreachable(origin)) {
        continue;
      }
      for (final candidate in candidates) {
        try {
          final uri = Uri.parse(origin).replace(
            path: '/artists',
            queryParameters: {'q': candidate},
          );
          final response = await _dio.get<String>(
            uri.toString(),
            options: _plainOptions(),
          );
          final match = _findFirstKemonoHtmlMatch(
            response.data ?? '',
            candidate,
            origin,
          );
          if (match != null) {
            return match;
          }
        } catch (error) {
          debugPrint('[xviewer][flutter] kemono creator lookup failed: $error');
        }
      }
    }
    return null;
  }

  Future<Object?> _fetchKemonoCreatorList(String origin, String endpoint) {
    final url = '$origin$endpoint';
    if (_disabledKemonoApiUrls.contains(url)) {
      return Future<Object?>.value(null);
    }
    return _kemonoCreatorListCache.putIfAbsent(url, () async {
      try {
        final response = await _dio.get<String>(
          url,
          options: _plainOptions(),
        );
        return jsonDecode(response.data ?? '');
      } catch (error) {
        _kemonoCreatorListCache.remove(url);
        _rememberUnreachableHost(error, origin);
        _rememberDisabledKemonoApi(error, url);
        rethrow;
      }
    });
  }

  CreatorSearchMatch? _findBestKemonoApiMatch(
    Object? data,
    List<String> candidates,
    String origin,
  ) {
    final entries = data is Map ? data['data'] : data;
    if (entries is! List) {
      return null;
    }

    CreatorSearchMatch? bestMatch;
    var bestScore = 0.0;

    for (final entry in entries.whereType<Map>()) {
      final name = (entry['name'] ?? '').toString();
      final service = (entry['service'] ?? '').toString();
      final id = (entry['id'] ?? entry['user_id'] ?? '').toString();
      if (name.isEmpty || service.isEmpty || id.isEmpty) {
        continue;
      }

      for (final candidate in candidates) {
        final score = _scoreFlexibleMatch(name, candidate);
        if (score > bestScore) {
          bestScore = score;
          bestMatch = CreatorSearchMatch(
            target: CreatorSearchTarget.kemono,
            title: name,
            url: '$origin/$service/user/$id',
          );
        }
      }
    }

    return bestScore >= 0.78 ? bestMatch : null;
  }

  CreatorSearchMatch? _findFirstKemonoHtmlMatch(
    String html,
    String candidate,
    String origin,
  ) {
    final linkPattern = RegExp(
      r'href="(/(?:patreon|fanbox|fantia|gumroad|subscribestar|dlsite|discord|boosty|afdian)/user/[^"]+)"',
      caseSensitive: false,
    );
    for (final match in linkPattern.allMatches(html)) {
      final start = (match.start - 220).clamp(0, html.length).toInt();
      final end = (match.end + 220).clamp(0, html.length).toInt();
      final surroundingText = _stripHtml(html.substring(start, end));
      if (_scoreFlexibleMatch(surroundingText, candidate) < 0.70) {
        continue;
      }
      return CreatorSearchMatch(
        target: CreatorSearchTarget.kemono,
        title: candidate,
        url: _absoluteUrl(origin, match.group(1) ?? ''),
      );
    }
    return null;
  }

  Future<List<CreatorSearchMatch>> _loadPersistedMatches(
    String authorUsername,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(StorageKeys.creatorSearchMatches);
    if (raw == null || raw.isEmpty) {
      return const <CreatorSearchMatch>[];
    }

    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      return const <CreatorSearchMatch>[];
    }

    final rawMatches = decoded[_normalizeUsername(authorUsername)];
    if (rawMatches is! List) {
      return const <CreatorSearchMatch>[];
    }

    return rawMatches.whereType<Map>().map((entry) {
      final targetName = (entry['target'] ?? '').toString();
      final target = _parseTarget(targetName);
      if (target == null) {
        return null;
      }
      final title = (entry['title'] ?? '').toString();
      final url = (entry['url'] ?? '').toString();
      if (title.isEmpty || url.isEmpty) {
        return null;
      }
      return CreatorSearchMatch(
        target: target,
        title: title,
        url: url,
      );
    }).whereType<CreatorSearchMatch>().toList(growable: false);
  }

  Future<void> _savePersistedMatches({
    required String authorUsername,
    required List<CreatorSearchMatch> matches,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(StorageKeys.creatorSearchMatches);
    final decoded = raw == null || raw.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(raw);
    final allMatches = decoded is Map
        ? Map<String, dynamic>.from(decoded)
        : <String, dynamic>{};
    allMatches[_normalizeUsername(authorUsername)] = matches.map((match) {
      return {
        'target': match.target.name,
        'title': match.title,
        'url': match.url,
      };
    }).toList(growable: false);
    await prefs.setString(
      StorageKeys.creatorSearchMatches,
      jsonEncode(allMatches),
    );
  }

  CreatorSearchTarget? _parseTarget(String value) {
    for (final target in CreatorSearchTarget.values) {
      if (target.name == value) {
        return target;
      }
    }
    return null;
  }

  Future<CreatorSearchMatch?> _resolveDddSmart(List<String> candidates) async {
    for (final candidate in candidates) {
      try {
        final uri = CreatorSearchTarget.dddSmart.buildUri(candidate);
        final response = await _dio.get<String>(
          uri.toString(),
          options: _plainOptions(),
        );
        final match = _findDddSmartMatch(
          uri: uri,
          html: response.data ?? '',
          candidate: candidate,
        );
        if (match != null) {
          return match;
        }
      } catch (error) {
        debugPrint('[xviewer][flutter] ddd-smart creator lookup failed: $error');
      }
    }
    return null;
  }

  CreatorSearchMatch? _findDddSmartMatch({
    required Uri uri,
    required String html,
    required String candidate,
  }) {
    final titleMatch = RegExp(
      r'<title>(.*?)</title>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(html);
    final title = _stripHtml(titleMatch?.group(1) ?? '');
    if (_scoreFlexibleMatch(title, candidate) < 0.70) {
      return null;
    }

    final countMatch = RegExp(r'-\s*(\d+)冊').firstMatch(title);
    final count = int.tryParse(countMatch?.group(1) ?? '');
    if (count == null || count <= 0) {
      return null;
    }

    return CreatorSearchMatch(
      target: CreatorSearchTarget.dddSmart,
      title: candidate,
      url: uri.toString(),
    );
  }

  List<String> _buildAuthorNameCandidates(String authorName) {
    final values = <String>[
      authorName,
      ..._nameVariants(authorName),
    ];
    return _normalizeCandidates(values);
  }

  List<String> _buildUsernameCandidates(String authorUsername) {
    final values = <String>[
      authorUsername,
      authorUsername.replaceAll('_', ' '),
      authorUsername.replaceAll('_', ''),
    ];
    return _normalizeCandidates(values);
  }

  List<String> _normalizeCandidates(List<String> values) {
    return values
        .map((value) => value.trim().replaceFirst(RegExp(r'^@+'), ''))
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }

  List<String> _nameVariants(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return const <String>[];
    }

    final withoutDecorations = trimmed
        .replaceAll(RegExp(r'[\(\[].*?[\)\]]'), ' ')
        .replaceAll(RegExp(r'@[a-zA-Z0-9_]+'), ' ')
        .replaceAll(
          RegExp(
            r'[^\u3040-\u30ff\u3400-\u9fffA-Za-z0-9_\s]+',
            unicode: true,
          ),
          ' ',
        )
        .trim();
    final splitParts = withoutDecorations
        .split(RegExp(r'[/|,\s]+'))
        .map((part) => part.trim())
        .where((part) => part.length >= 2);
    final compacted = withoutDecorations.replaceAll(RegExp(r'\s+'), '');

    return <String>[
      withoutDecorations,
      compacted,
      ...splitParts,
    ];
  }

  Options _plainOptions() {
    return Options(
      responseType: ResponseType.plain,
      receiveTimeout: const Duration(seconds: 8),
      sendTimeout: const Duration(seconds: 8),
      headers: const {
        'user-agent': 'XViewer creator lookup',
      },
    );
  }

  double _scoreMatch(String label, String candidate) {
    if (label.isEmpty || candidate.isEmpty) {
      return 0;
    }
    if (label == candidate) {
      return 1;
    }
    if (candidate.length >= 4 && label.contains(candidate)) {
      return 0.92;
    }
    if (label.length >= 4 && candidate.contains(label)) {
      return 0.86;
    }
    return _similarity(label, candidate);
  }

  double _scoreFlexibleMatch(String label, String candidate) {
    final normalizedLabel = _normalizeForMatch(label);
    final normalizedCandidate = _normalizeForMatch(candidate);
    final rawLabel = _normalizeText(label);
    final rawCandidate = _normalizeText(candidate);

    return [
      _scoreMatch(normalizedLabel, normalizedCandidate),
      _scoreTextContainment(rawLabel, rawCandidate),
    ].reduce((value, element) => value > element ? value : element);
  }

  double _scoreTextContainment(String label, String candidate) {
    if (label.isEmpty || candidate.isEmpty) {
      return 0;
    }
    if (label == candidate) {
      return 1;
    }
    if (candidate.length >= 2 && label.contains(candidate)) {
      return 0.92;
    }
    if (label.length >= 2 && candidate.contains(label)) {
      return 0.84;
    }
    return 0;
  }

  double _similarity(String a, String b) {
    final distance = _levenshtein(a, b);
    final maxLength = a.length > b.length ? a.length : b.length;
    if (maxLength == 0) {
      return 1;
    }
    return 1 - (distance / maxLength);
  }

  int _levenshtein(String a, String b) {
    final previous = List<int>.generate(b.length + 1, (index) => index);
    final current = List<int>.filled(b.length + 1, 0);

    for (var i = 0; i < a.length; i += 1) {
      current[0] = i + 1;
      for (var j = 0; j < b.length; j += 1) {
        final cost = a[i] == b[j] ? 0 : 1;
        current[j + 1] = [
          current[j] + 1,
          previous[j + 1] + 1,
          previous[j] + cost,
        ].reduce((value, element) => value < element ? value : element);
      }
      previous.setAll(0, current);
    }
    return previous[b.length];
  }

  String _normalizeForMatch(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  String _normalizeText(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'\s+'), '');
  }

  String _stripHtml(String value) {
    return value
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .trim();
  }

  String _absoluteUrl(String origin, String href) {
    if (href.startsWith('http://') || href.startsWith('https://')) {
      return href;
    }
    if (href.startsWith('/')) {
      return '$origin$href';
    }
    return '$origin/$href';
  }

  bool _isOriginUnreachable(String origin) {
    final host = Uri.parse(origin).host;
    return _unreachableHosts.contains(host);
  }

  void _rememberUnreachableHost(Object error, String origin) {
    final message = error.toString().toLowerCase();
    if (!message.contains('failed host lookup')) {
      return;
    }
    final host = Uri.parse(origin).host;
    _unreachableHosts.add(host);
    debugPrint(
      '[xviewer][flutter] Marked creator lookup host unreachable: $host',
    );
  }

  void _rememberDisabledKemonoApi(Object error, String url) {
    final statusCode = error is DioException ? error.response?.statusCode : null;
    if (statusCode != 403 && statusCode != 404) {
      return;
    }
    _disabledKemonoApiUrls.add(url);
  }

  String _normalizeUsername(String value) {
    return value.trim().replaceFirst(RegExp(r'^@+'), '').toLowerCase();
  }
}
