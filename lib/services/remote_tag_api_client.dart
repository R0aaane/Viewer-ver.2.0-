import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/mediaItem.dart';
import '../models/metadata_settings.dart';
import '../models/tag.dart';
import 'media_id_resolver.dart';

class MetadataException implements Exception {
  final String message;

  const MetadataException(this.message);

  @override
  String toString() => message;
}

class RemoteTagRecord {
  final String rawId;
  final Tag tag;

  const RemoteTagRecord({
    required this.rawId,
    required this.tag,
  });
}

class RemoteTagApiClient {
  final String baseUrl;
  final Duration timeout;
  final FutureOr<Map<String, String>> Function()? defaultHeadersProvider;

  const RemoteTagApiClient({
    required this.baseUrl,
    this.timeout = const Duration(seconds: 8),
    this.defaultHeadersProvider,
  });

  bool get isConfigured => baseUrl.trim().isNotEmpty;

  Future<MetadataConnectionStatus> checkHealth() async {
    if (!isConfigured) {
      return MetadataConnectionStatus(
        state: MetadataConnectionState.disconnected,
        message: 'API URL が未設定です',
        checkedAt: DateTime.now(),
      );
    }

    try {
      final json = await _getJson('/health');
      final message = switch (json) {
        Map<String, dynamic>() when json['message'] != null =>
          json['message'].toString(),
        Map<String, dynamic>() when json['service'] != null =>
          '${json['service']} に接続できました',
        _ => '接続確認に成功しました',
      };

      return MetadataConnectionStatus(
        state: MetadataConnectionState.connected,
        message: message,
        checkedAt: DateTime.now(),
      );
    } on MetadataException catch (error) {
      return MetadataConnectionStatus(
        state: MetadataConnectionState.disconnected,
        message: error.message,
        checkedAt: DateTime.now(),
      );
    }
  }

  Future<List<RemoteTagRecord>> fetchItemTags(String mediaId) async {
    final json = await _getJson('/tags/item/${Uri.encodeComponent(mediaId)}');
    final rows = _unwrapList(json, preferredKeys: const ['tags', 'items', 'results']);
    return rows.map(_parseRemoteTagRecord).toList(growable: false);
  }

  Future<void> addTagToItem(
    String mediaId,
    Tag tag, {
    ResolvedMediaIdentity? identity,
  }) async {
    await _postJson(
      '/tags/item/${Uri.encodeComponent(mediaId)}',
      <String, dynamic>{
        'tag': _tagToJson(tag),
        if (identity != null) 'identity': identity.toJson(),
      },
    );
  }

  Future<void> replaceTagsForItem(
    String mediaId,
    List<Tag> tags, {
    ResolvedMediaIdentity? identity,
  }) async {
    await _putJson(
      '/tags/item/${Uri.encodeComponent(mediaId)}',
      <String, dynamic>{
        'tags': tags.map(_tagToJson).toList(growable: false),
        if (identity != null) 'identity': identity.toJson(),
      },
    );
  }

  Future<void> deleteItemTag(String mediaId, String tagId) async {
    await _deleteJson('/tags/item/${Uri.encodeComponent(mediaId)}/${Uri.encodeComponent(tagId)}');
  }

  Future<List<RemoteTagRecord>> fetchMasterTags(
    TagCategory category, {
    String? contains,
    int limit = 200,
  }) async {
    final json = await _getJson(
      '/tags/master',
      queryParameters: <String, String>{
        'category': category.name,
        'limit': '$limit',
        if (contains != null && contains.trim().isNotEmpty)
          'contains': contains.trim(),
      },
    );
    final rows = _unwrapList(json, preferredKeys: const ['tags', 'items', 'results']);
    return rows.map(_parseRemoteTagRecord).toList(growable: false);
  }

  Future<Set<String>> searchItemIds({
    String? artist,
    String? series,
  }) async {
    final queryParameters = <String, String>{
      if (artist != null && artist.trim().isNotEmpty) 'artist': artist.trim(),
      if (series != null && series.trim().isNotEmpty) 'series': series.trim(),
    };
    final json = await _getJson('/search', queryParameters: queryParameters);
    return _extractItemIdSet(json);
  }

  Future<Set<String>> fetchUntaggedIds() async {
    final json = await _getJson('/untagged');
    return _extractItemIdSet(json);
  }

  Future<void> addTagBatch(List<ResolvedMediaIdentity> identities, Tag tag) async {
    await _postJson(
      '/tags/batch',
      <String, dynamic>{
        'tag': _tagToJson(tag),
        'items': identities.map((identity) => identity.toJson()).toList(growable: false),
      },
    );
  }

  Future<void> requestRescan() async {
    await _postJson('/rescan', const <String, dynamic>{});
  }

  Future<void> notifyRename({
    required MediaItem beforeItem,
    required MediaItem afterItem,
    required ResolvedMediaIdentity before,
    required ResolvedMediaIdentity after,
  }) async {
    await _postJson(
      '/rename',
      <String, dynamic>{
        'before': <String, dynamic>{
          ...before.toJson(),
          'path': beforeItem.id,
          'folderRaw': beforeItem.folderRaw,
          'displayName': beforeItem.displayName,
        },
        'after': <String, dynamic>{
          ...after.toJson(),
          'path': afterItem.id,
          'folderRaw': afterItem.folderRaw,
          'displayName': afterItem.displayName,
        },
      },
    );
  }

  Future<void> notifyDelete(
    List<(MediaItem, ResolvedMediaIdentity)> items, {
    required bool hardDelete,
  }) async {
    await _postJson(
      '/delete',
      <String, dynamic>{
        'hardDelete': hardDelete,
        'items': items
            .map(
              (entry) => <String, dynamic>{
                ...entry.$2.toJson(),
                'path': entry.$1.id,
                'folderRaw': entry.$1.folderRaw,
                'displayName': entry.$1.displayName,
                'hardDelete': hardDelete,
              },
            )
            .toList(growable: false),
      },
    );
  }

  Future<dynamic> _getJson(
    String path, {
    Map<String, String>? queryParameters,
  }) {
    return _requestJson('GET', path, queryParameters: queryParameters);
  }

  Future<dynamic> _postJson(String path, Map<String, dynamic> body) {
    return _requestJson('POST', path, body: body);
  }

  Future<dynamic> _putJson(String path, Map<String, dynamic> body) {
    return _requestJson('PUT', path, body: body);
  }

  Future<dynamic> _deleteJson(String path) {
    return _requestJson('DELETE', path);
  }

  Future<dynamic> _requestJson(
    String method,
    String path, {
    Map<String, String>? queryParameters,
    Map<String, dynamic>? body,
  }) async {
    final baseUri = _parseBaseUri();
    final uri = baseUri.replace(
      path: _joinPath(baseUri.path, path),
      queryParameters: queryParameters?.isEmpty == true ? null : queryParameters,
    );

    final client = HttpClient()
      ..connectionTimeout = timeout
      ..idleTimeout = timeout;

    try {
      final request = await _openRequest(client, method, uri);
      request.headers.contentType = ContentType.json;

      final headers = await defaultHeadersProvider?.call() ?? const <String, String>{};
      headers.forEach(request.headers.set);

      if (body != null) {
        request.write(jsonEncode(body));
      }

      final response = await request.close().timeout(timeout);
      final payload = await response.transform(utf8.decoder).join();
      final isJson = response.headers.contentType?.mimeType == ContentType.json.mimeType;
      final jsonBody = payload.trim().isEmpty
          ? null
          : (isJson ? jsonDecode(payload) : _tryDecodeJson(payload));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final message =
            _extractErrorMessage(jsonBody) ?? 'API エラー: HTTP ${response.statusCode}';
        throw MetadataException(message);
      }

      return jsonBody;
    } on TimeoutException {
      throw const MetadataException('API 応答がタイムアウトしました');
    } on SocketException {
      throw const MetadataException('API に接続できません。ネットワーク設定を確認してください');
    } on HttpException catch (error) {
      throw MetadataException('API 通信に失敗しました: ${error.message}');
    } on FormatException {
      throw const MetadataException('API 応答の形式が不正です');
    } finally {
      client.close(force: true);
    }
  }

  Future<HttpClientRequest> _openRequest(
    HttpClient client,
    String method,
    Uri uri,
  ) {
    switch (method) {
      case 'GET':
        return client.getUrl(uri);
      case 'POST':
        return client.postUrl(uri);
      case 'PUT':
        return client.putUrl(uri);
      case 'DELETE':
        return client.deleteUrl(uri);
      default:
        throw UnsupportedError('Unsupported method: $method');
    }
  }

  Uri _parseBaseUri() {
    final trimmed = baseUrl.trim();
    if (trimmed.isEmpty) {
      throw const MetadataException('API URL が未設定です');
    }

    Uri uri;
    try {
      uri = Uri.parse(trimmed);
    } catch (_) {
      throw const MetadataException('API URL の形式が不正です');
    }

    if (!uri.hasScheme || uri.host.isEmpty) {
      throw const MetadataException('API URL の形式が不正です');
    }
    return uri;
  }

  String _joinPath(String basePath, String childPath) {
    final left = basePath.endsWith('/')
        ? basePath.substring(0, basePath.length - 1)
        : basePath;
    final right = childPath.startsWith('/') ? childPath : '/$childPath';
    return '$left$right';
  }

  RemoteTagRecord _parseRemoteTagRecord(dynamic raw) {
    if (raw is String) {
      return RemoteTagRecord(rawId: raw, tag: Tag(name: raw));
    }

    if (raw is! Map) {
      throw const FormatException('Invalid tag payload');
    }

    final tagMap = raw['tag'] is Map ? raw['tag'] as Map : raw;
    final tagId =
        tagMap['tagId'] ?? tagMap['id'] ?? tagMap['remoteId'] ?? tagMap['name'];
    final name = tagMap['name']?.toString() ?? '';
    final categoryRaw = tagMap['category']?.toString() ?? TagCategory.free.name;

    return RemoteTagRecord(
      rawId: tagId.toString(),
      tag: Tag(
        name: name,
        category: _parseCategory(categoryRaw),
      ),
    );
  }

  TagCategory _parseCategory(String raw) {
    final normalized = raw.trim().toLowerCase();
    for (final category in TagCategory.values) {
      if (category.name.toLowerCase() == normalized) {
        return category;
      }
    }
    return TagCategory.free;
  }

  Map<String, dynamic> _tagToJson(Tag tag) {
    return <String, dynamic>{
      'name': tag.name,
      'category': tag.category.name,
    };
  }

  List<dynamic> _unwrapList(
    dynamic json, {
    List<String> preferredKeys = const [],
  }) {
    if (json is List) {
      return json;
    }
    if (json is Map<String, dynamic>) {
      for (final key in preferredKeys) {
        final value = json[key];
        if (value is List) {
          return value;
        }
      }
    }
    return const <dynamic>[];
  }

  Set<String> _extractItemIdSet(dynamic json) {
    final rows = _unwrapList(
      json,
      preferredKeys: const ['itemIds', 'ids', 'items', 'results'],
    );

    final out = <String>{};
    for (final row in rows) {
      if (row is String) {
        out.add(row);
        continue;
      }
      if (row is Map) {
        final value = row['mediaId'] ?? row['itemId'] ?? row['id'];
        if (value != null) {
          out.add(value.toString());
        }
      }
    }
    return out;
  }

  String? _extractErrorMessage(dynamic json) {
    if (json is Map<String, dynamic>) {
      final message = json['message'] ?? json['error'] ?? json['detail'];
      if (message != null) {
        return message.toString();
      }
    }
    return null;
  }

  dynamic _tryDecodeJson(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return <String, dynamic>{'message': raw};
    }
  }
}
