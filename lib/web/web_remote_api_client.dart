// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:pdfx/src/renderer/web/pdfjs.dart';

import '../models/tag.dart';

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

class WebRemoteEntry {
  final String entryId;
  final String displayName;
  final String folderRaw;
  final String kind;
  final String? mediaId;
  final String? fullPath;
  final int? sizeBytes;
  final DateTime? modifiedAt;

  const WebRemoteEntry({
    required this.entryId,
    required this.displayName,
    required this.folderRaw,
    required this.kind,
    required this.mediaId,
    required this.fullPath,
    required this.sizeBytes,
    required this.modifiedAt,
  });

  bool get isFolder => kind == 'folder';
  bool get isPdf => kind == 'pdf';
  bool get isImage => kind == 'image';

  String get stableId => mediaId ?? fullPath ?? entryId;
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
  });
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

  const WebRemoteApiClient({
    required this.baseUrl,
    this.authToken,
    this.timeout = const Duration(seconds: 20),
  });

  Future<void> checkHealth() async {
    final json = await _getJson('/health');
    if (json is! Map<String, dynamic> || json['ok'] != true) {
      throw const WebRemoteException('サーバーの応答を確認できませんでした');
    }
  }

  Future<List<WebRemoteFolder>> listFolders() async {
    final json = await _getJson('/folders');
    return _unwrapItems(json)
        .whereType<Map>()
        .map(_parseFolder)
        .where((folder) => folder.raw.trim().isNotEmpty)
        .toList(growable: false);
  }

  Future<List<WebRemoteEntry>> listFolderChildren(
    String folderRaw, {
    int limit = 200,
    int offset = 0,
  }) async {
    final json = await _getJson(
      '/folders/children',
      queryParameters: <String, String>{
        'folderRaw': folderRaw,
        'limit': '$limit',
        'offset': '$offset',
      },
    );
    return _unwrapItems(json)
        .whereType<Map>()
        .map(_parseEntry)
        .toList(growable: false);
  }

  Future<List<WebRemoteEntry>> search(
    WebSearchQuery query, {
    String? folderRaw,
    int limit = 200,
    int offset = 0,
  }) async {
    final json = await _getJson(
      query.untagged ? '/untagged' : '/search',
      queryParameters: <String, String>{
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
      },
    );

    return _unwrapItems(json)
        .whereType<Map>()
        .map(_parseEntry)
        .toList(growable: false);
  }

  Future<List<Tag>> fetchItemTags(String mediaId) async {
    final json = await _getJson('/items/${Uri.encodeComponent(mediaId)}/tags');
    return _unwrapItems(json)
        .whereType<Map>()
        .map(_parseTag)
        .toList(growable: false);
  }

  Future<WebRemoteMediaMeta> fetchMediaMeta(String mediaId) async {
    final json = await _getJson('/media/${Uri.encodeComponent(mediaId)}/meta');
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
    );
  }

  Future<Uint8List> fetchThumbnail(
    String mediaId, {
    int? width,
    int? height,
    int? page,
  }) {
    return _getBytes(
      '/media/${Uri.encodeComponent(mediaId)}/thumb',
      queryParameters: <String, String>{
        if (width != null) 'width': '$width',
        if (height != null) 'height': '$height',
        if (page != null) 'page': '$page',
      },
    );
  }

  Future<Uint8List> fetchPdfPage(
    String mediaId,
    int pageNo, {
    int? width,
  }) {
    return _getBytes(
      '/media/${Uri.encodeComponent(mediaId)}/page/$pageNo',
      queryParameters: <String, String>{
        if (width != null) 'width': '$width',
      },
    );
  }

  Future<int> resolvePdfPageCount(
    String mediaId, {
    int? pageCountHint,
  }) async {
    if (pageCountHint != null && pageCountHint > 0) {
      return pageCountHint;
    }

    try {
      final bytes = Uint8List.fromList(await fetchImageDownload(mediaId));
      final document = await pdfjsGetDocumentFromData(bytes.buffer);
      try {
        return document.numPages;
      } finally {
        document.destroy();
      }
    } catch (_) {
      return _resolvePdfPageCountByPageProbe(mediaId);
    }
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
      await fetchThumbnail(
        mediaId,
        width: 64,
        height: 64,
        page: pageNo,
      );
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
    return _getBytes('/media/${Uri.encodeComponent(mediaId)}/download');
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
    final raw = await _requestText('GET', path, queryParameters: queryParameters);
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
  }) async {
    try {
      final request = await html.HttpRequest.request(
        _buildUri(path, queryParameters: queryParameters).toString(),
        method: method,
        sendData: body == null ? null : jsonEncode(body),
        requestHeaders: _buildHeaders(jsonBody: body != null),
      ).timeout(timeout);

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
  }) async {
    try {
      final request = await html.HttpRequest.request(
        _buildUri(path, queryParameters: queryParameters).toString(),
        method: 'GET',
        responseType: 'arraybuffer',
        requestHeaders: _buildHeaders(),
      ).timeout(timeout);

      final status = request.status ?? 0;
      final bytes = _responseBytes(request.response);
      if (status < 200 || status >= 300) {
        final raw = utf8.decode(bytes, allowMalformed: true);
        throw WebRemoteException(
          _extractErrorMessage(raw) ?? _messageForStatus(status),
          statusCode: status,
        );
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

  Uri _buildUri(
    String path, {
    Map<String, String>? queryParameters,
  }) {
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
      queryParameters: queryParameters?.isEmpty == true ? null : queryParameters,
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
    );
  }

  Tag _parseTag(Map raw) {
    return Tag(
      name: raw['name']?.toString() ?? '',
      category: _parseTagCategory(raw['category']?.toString()),
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
