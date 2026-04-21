import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/metadata_settings.dart';

class AppUpdatePublishException implements Exception {
  final String message;
  final int? statusCode;

  const AppUpdatePublishException(this.message, {this.statusCode});

  @override
  String toString() => message;
}

class AppUpdatePublishResult {
  final String version;
  final String fileName;
  final String originalFileName;
  final int sizeBytes;
  final String updateUrl;

  const AppUpdatePublishResult({
    required this.version,
    required this.fileName,
    required this.originalFileName,
    required this.sizeBytes,
    required this.updateUrl,
  });
}

class AppUpdatePublishService {
  final Duration timeout;

  const AppUpdatePublishService({this.timeout = const Duration(minutes: 10)});

  Future<AppUpdatePublishResult> uploadUpdate({
    required MetadataSettings settings,
    required String version,
    required String filePath,
    required String fileName,
  }) async {
    final normalizedVersion = version.trim();
    if (normalizedVersion.isEmpty) {
      throw const AppUpdatePublishException('公開バージョンを入力してください');
    }

    final trimmedPath = filePath.trim();
    if (trimmedPath.isEmpty) {
      throw const AppUpdatePublishException('アップデートファイルを選択できませんでした');
    }

    final file = File(trimmedPath);
    final sizeBytes = await file.length();
    if (sizeBytes <= 0) {
      throw const AppUpdatePublishException('アップデートファイルが空です');
    }

    final baseUrl = _baseUrlForSettings(settings);
    if (baseUrl.isEmpty) {
      throw const AppUpdatePublishException('ホスト API URL が未設定です');
    }

    final uri = _buildUri(baseUrl, '/app-update/upload');
    final boundary =
        '----pdf-viewer-update-${DateTime.now().millisecondsSinceEpoch}';
    final multipartFileName = _safeMultipartFileName(
      fileName.trim().isNotEmpty ? fileName : p.basename(trimmedPath),
    );
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..idleTimeout = timeout;

    try {
      final request = await client.postUrl(uri);
      _applyAuthHeader(request.headers, settings.authToken);
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'multipart/form-data; boundary=$boundary',
      );

      void writeAscii(String value) {
        request.add(ascii.encode(value));
      }

      void writeUtf8(String value) {
        request.add(utf8.encode(value));
      }

      void writeField(String name, String value) {
        writeAscii('--$boundary\r\n');
        writeAscii('Content-Disposition: form-data; name="$name"\r\n');
        writeAscii('Content-Type: text/plain; charset=utf-8\r\n\r\n');
        writeUtf8(value);
        writeAscii('\r\n');
      }

      writeField('version', normalizedVersion);
      writeAscii('--$boundary\r\n');
      writeAscii(
        'Content-Disposition: form-data; name="file"; '
        'filename="${_escapeQuoted(multipartFileName)}"\r\n',
      );
      writeAscii('Content-Type: application/octet-stream\r\n\r\n');
      await for (final chunk in file.openRead()) {
        request.add(chunk);
      }
      writeAscii('\r\n--$boundary--\r\n');

      final response = await request.close().timeout(timeout);
      final payload = await response
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(timeout);
      final jsonBody = payload.trim().isEmpty ? null : _tryDecodeJson(payload);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AppUpdatePublishException(
          _extractErrorMessage(jsonBody) ??
              _messageForStatus(response.statusCode),
          statusCode: response.statusCode,
        );
      }

      if (jsonBody is! Map<String, dynamic>) {
        throw const AppUpdatePublishException('ホストの応答形式が不正です');
      }

      final publishedVersion = jsonBody['version']?.toString().trim();
      final publishedFileName = jsonBody['fileName']?.toString().trim();
      final originalFileName = jsonBody['originalFileName']?.toString().trim();
      final updateUrl = _resolveUpdateUrl(baseUrl, jsonBody['updateUrl']);
      return AppUpdatePublishResult(
        version: publishedVersion?.isNotEmpty == true
            ? publishedVersion!
            : normalizedVersion,
        fileName: publishedFileName?.isNotEmpty == true
            ? publishedFileName!
            : multipartFileName,
        originalFileName: originalFileName?.isNotEmpty == true
            ? originalFileName!
            : multipartFileName,
        sizeBytes: _asInt(jsonBody['sizeBytes']) ?? sizeBytes,
        updateUrl: updateUrl,
      );
    } on TimeoutException {
      throw const AppUpdatePublishException('ホストの応答がタイムアウトしました');
    } on SocketException {
      throw const AppUpdatePublishException('ホスト API に接続できません');
    } finally {
      client.close(force: true);
    }
  }

  String _baseUrlForSettings(MetadataSettings settings) {
    switch (settings.appMode) {
      case AppMode.host:
        return settings.hostLoopbackApiBaseUrl.trim();
      case AppMode.client:
        return settings.remoteApiBaseUrl.trim();
      case AppMode.standalone:
        return '';
    }
  }

  Uri _buildUri(String baseUrl, String path) {
    final uri = Uri.tryParse(baseUrl.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw const AppUpdatePublishException('ホスト API URL の形式が不正です');
    }
    return uri.replace(path: _joinPath(uri.path, path));
  }

  String _joinPath(String basePath, String childPath) {
    final left = basePath.endsWith('/')
        ? basePath.substring(0, basePath.length - 1)
        : basePath;
    final right = childPath.startsWith('/') ? childPath : '/$childPath';
    return '$left$right';
  }

  void _applyAuthHeader(HttpHeaders headers, String? authToken) {
    final token = authToken?.trim();
    if (token != null && token.isNotEmpty) {
      headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
  }

  String _resolveUpdateUrl(String baseUrl, Object? value) {
    final raw = value?.toString().trim() ?? '';
    if (raw.isEmpty) {
      return '';
    }
    final uri = Uri.tryParse(raw);
    if (uri != null && uri.hasScheme) {
      return raw;
    }
    return Uri.parse(baseUrl).resolve(raw).toString();
  }

  String _safeMultipartFileName(String value) {
    final basename = p.basename(value.replaceAll('\\', '/')).trim();
    final sanitized = basename.replaceAll(RegExp(r'[^0-9A-Za-z._ +()-]+'), '_');
    return sanitized.isEmpty ? 'app-update.zip' : sanitized;
  }

  String _escapeQuoted(String value) {
    return value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  }

  int? _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '');
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
        return 'ホスト API が見つかりません';
      default:
        if (statusCode >= 500) {
          return 'ホスト側でエラーが発生しました';
        }
        return 'API エラー: HTTP $statusCode';
    }
  }
}
