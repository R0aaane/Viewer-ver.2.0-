import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/folder.dart';
import '../repository/mediaRepository.dart';

class RemoteMediaException implements Exception {
  final String message;
  final int? statusCode;

  const RemoteMediaException(this.message, {this.statusCode});

  @override
  String toString() => message;
}

class RemoteUploadFile {
  final String fileName;
  final Uint8List bytes;
  final String mimeType;

  const RemoteUploadFile({
    required this.fileName,
    required this.bytes,
    required this.mimeType,
  });
}

class RemoteUploadResponse {
  final int importedCount;
  final int skippedCount;

  const RemoteUploadResponse({
    required this.importedCount,
    required this.skippedCount,
  });
}

class RemoteMediaMeta {
  final String mediaId;
  final String displayName;
  final String kind;
  final String? mimeType;
  final int? sizeBytes;
  final DateTime? modifiedAt;
  final String? etag;
  final bool supportsRange;

  const RemoteMediaMeta({
    required this.mediaId,
    required this.displayName,
    required this.kind,
    required this.mimeType,
    required this.sizeBytes,
    required this.modifiedAt,
    required this.etag,
    required this.supportsRange,
  });
}

class RemoteFolderEntry {
  final String entryId;
  final String displayName;
  final String folderRaw;
  final String kind;
  final String? mediaId;
  final String? fullPath;
  final int? sizeBytes;
  final DateTime? modifiedAt;

  const RemoteFolderEntry({
    required this.entryId,
    required this.displayName,
    required this.folderRaw,
    required this.kind,
    required this.mediaId,
    required this.fullPath,
    required this.sizeBytes,
    required this.modifiedAt,
  });
}

class RemoteFolderPage {
  final List<RemoteFolderEntry> items;
  final int total;
  final int limit;
  final int offset;

  const RemoteFolderPage({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
  });
}

class RemoteMediaPage {
  final List<RemoteFolderEntry> items;
  final int total;
  final int limit;
  final int offset;

  const RemoteMediaPage({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
  });
}

class RemoteMediaApiClient {
  final String baseUrl;
  final String? authToken;
  final Duration timeout;

  const RemoteMediaApiClient({
    required this.baseUrl,
    this.authToken,
    this.timeout = const Duration(seconds: 15),
  });

  bool get isConfigured => baseUrl.trim().isNotEmpty;

  Future<List<FolderHandle>> listAvailableFolders() async {
    final json = await _getJson('/folders');
    final rows = _unwrapList(json, preferredKeys: const ['items', 'results']);
    return rows
        .whereType<Map>()
        .map((row) => FolderHandle(row['folderRaw']?.toString() ?? ''))
        .where((folder) => folder.raw.trim().isNotEmpty)
        .toList(growable: false);
  }

  Future<RemoteFolderPage> listFolderChildren(
    String folderRaw, {
    int limit = 100,
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

    final rows = _unwrapList(json, preferredKeys: const ['items', 'results']);
    return RemoteFolderPage(
      items: rows.map(_parseFolderEntry).toList(growable: false),
      total: _asInt(json['total']) ?? rows.length,
      limit: _asInt(json['limit']) ?? limit,
      offset: _asInt(json['offset']) ?? offset,
    );
  }

  Future<RemoteMediaPage> searchMedia({
    String? folderRaw,
    int limit = 200,
    int offset = 0,
  }) async {
    final json = await _getJson(
      '/search',
      queryParameters: <String, String>{
        if (folderRaw != null && folderRaw.trim().isNotEmpty)
          'folderRaw': folderRaw,
        'limit': '$limit',
        'offset': '$offset',
      },
    );

    final rows = _unwrapList(json, preferredKeys: const ['items', 'results']);
    return RemoteMediaPage(
      items: rows.map(_parseSearchEntry).toList(growable: false),
      total: _asInt(json['total']) ?? rows.length,
      limit: _asInt(json['limit']) ?? limit,
      offset: _asInt(json['offset']) ?? offset,
    );
  }

  Future<RemoteMediaMeta> fetchMediaMeta(String mediaId) async {
    final json = await _getJson('/media/${Uri.encodeComponent(mediaId)}/meta');
    if (json is! Map<String, dynamic>) {
      throw const RemoteMediaException('メディア情報の形式が不正です');
    }
    return RemoteMediaMeta(
      mediaId: json['mediaId']?.toString() ?? mediaId,
      displayName: json['displayName']?.toString() ?? mediaId,
      kind: json['kind']?.toString() ?? 'image',
      mimeType: json['mimeType']?.toString(),
      sizeBytes: _asInt(json['sizeBytes']),
      modifiedAt: _parseDateTime(json['modifiedAt']?.toString()),
      etag: json['etag']?.toString(),
      supportsRange: json['supportsRange'] == true,
    );
  }

  Future<void> downloadMediaToFile(String mediaId, File destination) async {
    final uri = _buildUri('/media/${Uri.encodeComponent(mediaId)}/download');
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..idleTimeout = timeout;

    IOSink? sink;
    try {
      final request = await client.getUrl(uri);
      _applyHeaders(request.headers);
      final response = await request.close().timeout(timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final payload = await response.transform(utf8.decoder).join();
        final jsonBody = payload.trim().isEmpty ? null : _tryDecodeJson(payload);
        throw RemoteMediaException(
          _extractErrorMessage(jsonBody) ?? _messageForStatus(response.statusCode),
          statusCode: response.statusCode,
        );
      }

      await destination.parent.create(recursive: true);
      sink = destination.openWrite();
      await response.forEach(sink.add);
      await sink.flush();
    } on TimeoutException {
      await sink?.close();
      try {
        if (await destination.exists()) {
          await destination.delete();
        }
      } catch (_) {}
      throw const RemoteMediaException('サーバー応答がタイムアウトしました');
    } on SocketException {
      await sink?.close();
      try {
        if (await destination.exists()) {
          await destination.delete();
        }
      } catch (_) {}
      throw const RemoteMediaException('サーバーに接続できません');
    } catch (_) {
      await sink?.close();
      try {
        if (await destination.exists()) {
          await destination.delete();
        }
      } catch (_) {}
      rethrow;
    } finally {
      await sink?.close();
      client.close(force: true);
    }
  }

  Future<Uint8List> fetchThumbnail(
    String mediaId, {
    int? width,
    int? height,
    int? page,
  }) async {
    return _getBytes(
      '/media/${Uri.encodeComponent(mediaId)}/thumb',
      queryParameters: <String, String>{
        if (width != null) 'width': '$width',
        if (height != null) 'height': '$height',
        if (page != null) 'page': '$page',
      },
    );
  }

  Future<Uint8List> fetchPageImage(
    String mediaId,
    int pageNo, {
    int? width,
  }) async {
    return _getBytes(
      '/media/${Uri.encodeComponent(mediaId)}/page/$pageNo',
      queryParameters: <String, String>{
        if (width != null) 'width': '$width',
      },
    );
  }

  Future<RemoteUploadResponse> uploadFiles({
    required String folderRaw,
    required List<RemoteUploadFile> files,
    bool skipIfExists = true,
    void Function(MediaTransferProgress progress)? onProgress,
  }) async {
    if (files.isEmpty) {
      return const RemoteUploadResponse(importedCount: 0, skippedCount: 0);
    }

    final uri = _buildUri('/upload');
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..idleTimeout = timeout;

    final boundary = '----pdf-viewer-${DateTime.now().millisecondsSinceEpoch}';
    final totalBytes = files.fold<int>(
      0,
      (sum, file) => sum + file.bytes.length,
    );
    var sentBytes = 0;
    var completedFiles = 0;
    const chunkSize = 256 * 1024;

    try {
      final request = await client.postUrl(uri);
      _applyHeaders(request.headers);
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'multipart/form-data; boundary=$boundary',
      );

      void writeField(String name, String value) {
        request.write('--$boundary\r\n');
        request.write('Content-Disposition: form-data; name="$name"\r\n\r\n');
        request.write(value);
        request.write('\r\n');
      }

      writeField('folderRaw', folderRaw);
      writeField('skipIfExists', skipIfExists ? 'true' : 'false');

      onProgress?.call(
        MediaTransferProgress(
          sentBytes: 0,
          totalBytes: totalBytes,
          completedFiles: 0,
          totalFiles: files.length,
        ),
      );

      for (final file in files) {
        request.write('--$boundary\r\n');
        request.write(
          'Content-Disposition: form-data; name="files"; filename="${_escapeQuoted(file.fileName)}"\r\n',
        );
        request.write('Content-Type: ${file.mimeType}\r\n\r\n');
        for (var offset = 0; offset < file.bytes.length; offset += chunkSize) {
          final end = (offset + chunkSize) > file.bytes.length
              ? file.bytes.length
              : (offset + chunkSize);
          request.add(Uint8List.sublistView(file.bytes, offset, end));
          sentBytes += end - offset;
          onProgress?.call(
            MediaTransferProgress(
              sentBytes: sentBytes,
              totalBytes: totalBytes,
              completedFiles: completedFiles,
              totalFiles: files.length,
              currentFileName: file.fileName,
            ),
          );
        }
        request.write('\r\n');

        completedFiles++;
        onProgress?.call(
          MediaTransferProgress(
            sentBytes: sentBytes,
            totalBytes: totalBytes,
            completedFiles: completedFiles,
            totalFiles: files.length,
            currentFileName: file.fileName,
          ),
        );
      }

      request.write('--$boundary--\r\n');

      final response = await request.close().timeout(timeout);
      final payload = await response.transform(utf8.decoder).join();
      final jsonBody = payload.trim().isEmpty ? null : _tryDecodeJson(payload);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw RemoteMediaException(
          _extractErrorMessage(jsonBody) ?? _messageForStatus(response.statusCode),
          statusCode: response.statusCode,
        );
      }

      if (jsonBody is! Map<String, dynamic>) {
        return RemoteUploadResponse(
          importedCount: files.length,
          skippedCount: 0,
        );
      }

      return RemoteUploadResponse(
        importedCount:
            _asInt(jsonBody['importedCount']) ??
            _asInt(jsonBody['count']) ??
            files.length,
        skippedCount: _asInt(jsonBody['skippedCount']) ?? 0,
      );
    } on TimeoutException {
      throw const RemoteMediaException('アップロードがタイムアウトしました');
    } on SocketException {
      throw const RemoteMediaException('サーバーに接続できません');
    } finally {
      client.close(force: true);
    }
  }

  Future<dynamic> _getJson(
    String path, {
    Map<String, String>? queryParameters,
  }) async {
    final bytes = await _getBytes(path, queryParameters: queryParameters);
    final raw = utf8.decode(bytes);
    if (raw.trim().isEmpty) {
      return <String, dynamic>{};
    }
    return jsonDecode(raw);
  }

  Future<Uint8List> _getBytes(
    String path, {
    Map<String, String>? queryParameters,
  }) async {
    final uri = _buildUri(path, queryParameters: queryParameters);
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..idleTimeout = timeout;

    try {
      final request = await client.getUrl(uri);
      _applyHeaders(request.headers);
      final response = await request.close().timeout(timeout);
      final chunks = <int>[];
      await for (final chunk in response) {
        chunks.addAll(chunk);
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final raw = utf8.decode(chunks, allowMalformed: true);
        final jsonBody = raw.trim().isEmpty ? null : _tryDecodeJson(raw);
        throw RemoteMediaException(
          _extractErrorMessage(jsonBody) ?? _messageForStatus(response.statusCode),
          statusCode: response.statusCode,
        );
      }

      return Uint8List.fromList(chunks);
    } on TimeoutException {
      throw const RemoteMediaException('サーバー応答がタイムアウトしました');
    } on SocketException {
      throw const RemoteMediaException('サーバーに接続できません');
    } finally {
      client.close(force: true);
    }
  }

  Uri _buildUri(
    String path, {
    Map<String, String>? queryParameters,
  }) {
    final baseUri = _parseBaseUri();
    return baseUri.replace(
      path: _joinPath(baseUri.path, path),
      queryParameters: queryParameters?.isEmpty == true ? null : queryParameters,
    );
  }

  void _applyHeaders(HttpHeaders headers) {
    final token = authToken?.trim();
    if (token != null && token.isNotEmpty) {
      headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
  }

  Uri _parseBaseUri() {
    final trimmed = baseUrl.trim();
    if (trimmed.isEmpty) {
      throw const RemoteMediaException('API URL が未設定です');
    }

    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw const RemoteMediaException('API URL の形式が不正です');
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

  String _escapeQuoted(String value) {
    return value.replaceAll('"', '\\"');
  }

  RemoteFolderEntry _parseFolderEntry(dynamic raw) {
    if (raw is! Map) {
      throw const RemoteMediaException('フォルダ一覧の形式が不正です');
    }
    return RemoteFolderEntry(
      entryId: raw['entryId']?.toString() ?? raw['fullPath']?.toString() ?? '',
      displayName: raw['displayName']?.toString() ?? '',
      folderRaw: raw['folderRaw']?.toString() ?? '',
      kind: raw['kind']?.toString() ?? 'folder',
      mediaId: raw['mediaId']?.toString(),
      fullPath: raw['fullPath']?.toString(),
      sizeBytes: _asInt(raw['sizeBytes']),
      modifiedAt: _parseDateTime(raw['modifiedAt']?.toString()),
    );
  }

  RemoteFolderEntry _parseSearchEntry(dynamic raw) {
    if (raw is! Map) {
      throw const RemoteMediaException('検索結果の形式が不正です');
    }
    return RemoteFolderEntry(
      entryId:
          raw['fullPath']?.toString() ??
          raw['mediaId']?.toString() ??
          raw['entryId']?.toString() ??
          '',
      displayName: raw['displayName']?.toString() ?? '',
      folderRaw: raw['folderRaw']?.toString() ?? '',
      kind: raw['kind']?.toString() ?? 'image',
      mediaId: raw['mediaId']?.toString(),
      fullPath: raw['fullPath']?.toString(),
      sizeBytes: _asInt(raw['sizeBytes']),
      modifiedAt: _parseDateTime(raw['modifiedAt']?.toString()),
    );
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

  DateTime? _parseDateTime(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    return DateTime.tryParse(raw);
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

  String _messageForStatus(int statusCode) {
    switch (statusCode) {
      case 401:
      case 403:
        return '認証に失敗しました。トークンを確認してください';
      case 404:
        return '対象が見つかりません';
      case 409:
        return '同名ファイルがすでに存在します';
      case 410:
        return '対象は削除済みです';
      default:
        if (statusCode >= 500) {
          return 'サーバーエラーが発生しました';
        }
        return 'API エラー: HTTP $statusCode';
    }
  }
}
