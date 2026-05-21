import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../services/app_settings_service.dart';
import '../core/errors/app_exception.dart';

class HostSavedImageResult {
  const HostSavedImageResult({
    required this.savedPath,
    required this.displayName,
  });

  final String savedPath;
  final String displayName;
}

class HostSavedImageItem {
  const HostSavedImageItem({
    required this.relativePath,
    required this.fileName,
    required this.authorUsername,
    required this.savedPath,
    required this.downloadUrl,
    required this.modifiedAt,
  });

  final String relativePath;
  final String fileName;
  final String authorUsername;
  final String savedPath;
  final String downloadUrl;
  final DateTime modifiedAt;
}

class HostSavedImagesService {
  HostSavedImagesService({AppSettingsService? settingsService})
    : _settingsService = settingsService ?? AppSettingsService();

  final AppSettingsService _settingsService;

  Future<bool> shouldSaveToHost() async {
    final settings = await _settingsService.loadMetadataSettings();
    return _resolveHostApiBaseUrl(settings).isNotEmpty;
  }

  Future<String?> getHostDescription() async {
    final settings = await _settingsService.loadMetadataSettings();
    final baseUrl = _resolveHostApiBaseUrl(settings);
    if (baseUrl.isEmpty) {
      return null;
    }
    return 'Host Xsaved_images endpoint: $baseUrl';
  }

  Future<HostSavedImageResult> saveImage({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
    required String accountFolderName,
  }) async {
    final settings = await _settingsService.loadMetadataSettings();
    final baseUrl = _resolveHostApiBaseUrl(settings);
    if (baseUrl.isEmpty) {
      throw const AppException('Host save is not configured.');
    }

    final uri = Uri.parse('$baseUrl/xviewer/saved-images');
    final boundary = '----xviewer-${DateTime.now().millisecondsSinceEpoch}';
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(minutes: 5);

    try {
      final request = await client.postUrl(uri);
      final token = settings.authToken?.trim();
      if (token != null && token.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'multipart/form-data; boundary=$boundary',
      );

      void writeAscii(String value) => request.add(ascii.encode(value));
      void writeUtf8(String value) => request.add(utf8.encode(value));

      void writeField(String name, String value) {
        writeAscii('--$boundary\r\n');
        writeAscii('Content-Disposition: form-data; name="$name"\r\n');
        writeAscii('Content-Type: text/plain; charset=utf-8\r\n\r\n');
        writeUtf8(value);
        writeAscii('\r\n');
      }

      writeField('accountFolderName', accountFolderName);
      writeAscii('--$boundary\r\n');
      writeAscii(
        'Content-Disposition: form-data; name="file"; filename="${_escapeQuoted(fileName)}"\r\n',
      );
      writeAscii('Content-Type: $mimeType\r\n\r\n');
      request.add(bytes);
      writeAscii('\r\n--$boundary--\r\n');

      final response = await request.close().timeout(
        const Duration(minutes: 5),
      );
      final payload = await response
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(const Duration(minutes: 5));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AppException('Host Saved_images save failed.', details: payload);
      }

      final json = jsonDecode(payload) as Map<String, dynamic>;
      return HostSavedImageResult(
        savedPath: json['savedPath']?.toString() ?? '',
        displayName: json['displayName']?.toString() ?? fileName,
      );
    } on TimeoutException catch (error) {
      throw AppException('Host Saved_images save timed out.', details: error);
    } finally {
      client.close(force: true);
    }
  }

  Future<List<HostSavedImageItem>> listSavedImages() async {
    final settings = await _settingsService.loadMetadataSettings();
    final baseUrl = _resolveHostApiBaseUrl(settings);
    if (baseUrl.isEmpty) {
      return const <HostSavedImageItem>[];
    }

    final request = await _openGet('$baseUrl/xviewer/saved-images', settings);
    final response = await request.close().timeout(const Duration(seconds: 30));
    final payload = await response
        .transform(const Utf8Decoder(allowMalformed: true))
        .join()
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AppException('Host Saved_images list failed.', details: payload);
    }

    final json = jsonDecode(payload) as Map<String, dynamic>;
    final rawItems = json['items'];
    if (rawItems is! List) {
      return const <HostSavedImageItem>[];
    }

    return rawItems
        .whereType<Map>()
        .map((raw) {
          final downloadPath = raw['downloadPath']?.toString() ?? '';
          final modifiedEpochMs =
              int.tryParse(raw['modifiedEpochMs']?.toString() ?? '') ??
              DateTime.now().millisecondsSinceEpoch;
          return HostSavedImageItem(
            relativePath: raw['relativePath']?.toString() ?? '',
            fileName: raw['fileName']?.toString() ?? 'image.jpg',
            authorUsername: raw['authorUsername']?.toString() ?? 'unknown_user',
            savedPath: raw['savedPath']?.toString() ?? '',
            downloadUrl: downloadPath.startsWith('http')
                ? downloadPath
                : '$baseUrl$downloadPath',
            modifiedAt: DateTime.fromMillisecondsSinceEpoch(modifiedEpochMs),
          );
        })
        .where((item) {
          return item.relativePath.isNotEmpty && item.downloadUrl.isNotEmpty;
        })
        .toList(growable: false);
  }

  Future<Uint8List> downloadSavedImage(HostSavedImageItem item) async {
    final settings = await _settingsService.loadMetadataSettings();
    final request = await _openGet(item.downloadUrl, settings);
    final response = await request.close().timeout(const Duration(minutes: 5));
    final bytes = await consolidateHttpClientResponseBytes(
      response,
    ).timeout(const Duration(minutes: 5));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AppException(
        'Host Saved_images download failed.',
        details: item.relativePath,
      );
    }
    return bytes;
  }

  Future<HttpClientRequest> _openGet(String url, dynamic settings) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(minutes: 5);
    final request = await client.getUrl(Uri.parse(url));
    final token = settings.authToken?.trim();
    if (token != null && token.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    return request;
  }

  String _escapeQuoted(String value) {
    return value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  }

  String _resolveHostApiBaseUrl(dynamic settings) {
    final storedApi = settings.clientApiBaseUrl.trim();
    if (storedApi.isNotEmpty) {
      return storedApi.replaceAll(RegExp(r'/+$'), '');
    }
    if (settings.isHostMode) {
      return settings.hostLoopbackApiBaseUrl.trim().replaceAll(
        RegExp(r'/+$'),
        '',
      );
    }
    return '';
  }
}
