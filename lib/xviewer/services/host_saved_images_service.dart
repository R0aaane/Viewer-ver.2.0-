import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

class HostSavedImagesService {
  HostSavedImagesService({AppSettingsService? settingsService})
    : _settingsService = settingsService ?? AppSettingsService();

  final AppSettingsService _settingsService;

  Future<bool> shouldSaveToHost() async {
    final settings = await _settingsService.loadMetadataSettings();
    return settings.isClientMode && settings.clientApiBaseUrl.trim().isNotEmpty;
  }

  Future<String?> getHostDescription() async {
    final settings = await _settingsService.loadMetadataSettings();
    if (!settings.isClientMode || settings.clientApiBaseUrl.trim().isEmpty) {
      return null;
    }
    return 'Host Xsaved_images endpoint: ${settings.clientApiBaseUrl.trim()}';
  }

  Future<HostSavedImageResult> saveImage({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
    required String accountFolderName,
  }) async {
    final settings = await _settingsService.loadMetadataSettings();
    if (!settings.isClientMode || settings.clientApiBaseUrl.trim().isEmpty) {
      throw const AppException('Host save is not configured.');
    }

    final uri = Uri.parse(
      '${settings.clientApiBaseUrl.trim().replaceAll(RegExp(r'/+$'), '')}/xviewer/saved-images',
    );
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

  String _escapeQuoted(String value) {
    return value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  }
}
