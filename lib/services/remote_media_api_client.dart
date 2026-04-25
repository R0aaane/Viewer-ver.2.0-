import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/mediaItem.dart';
import '../models/reading_progress.dart';
import '../models/tag.dart';
import '../models/folder.dart';
import '../repository/mediaRepository.dart';
import 'import_source_normalizer.dart';
import 'media_id_resolver.dart';

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
  final String? sourceRelativePath;
  final List<Tag> tags;

  const RemoteUploadFile({
    required this.fileName,
    required this.bytes,
    required this.mimeType,
    this.sourceRelativePath,
    this.tags = const <Tag>[],
  });
}

class RemoteUploadedMediaTags {
  final String mediaId;
  final List<String> tags;

  const RemoteUploadedMediaTags({
    required this.mediaId,
    this.tags = const <String>[],
  });
}

class RemoteUploadResponse {
  final int importedCount;
  final int skippedCount;
  final int taggedCount;
  final int organizedCount;
  final int rescannedCount;
  final String? requestId;
  final int tagAttachSuccessCount;
  final int tagAttachFailureCount;
  final List<RemoteUploadedMediaTags> attachedTagsByMedia;

  const RemoteUploadResponse({
    required this.importedCount,
    required this.skippedCount,
    this.taggedCount = 0,
    this.organizedCount = 0,
    this.rescannedCount = 0,
    this.requestId,
    this.tagAttachSuccessCount = 0,
    this.tagAttachFailureCount = 0,
    this.attachedTagsByMedia = const <RemoteUploadedMediaTags>[],
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
  final int? pageCount;

  const RemoteMediaMeta({
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

class RemoteMediaActivityEntry {
  final String mediaId;
  final String folderRaw;
  final DateTime viewedAt;
  final int? lastPage;

  const RemoteMediaActivityEntry({
    required this.mediaId,
    required this.folderRaw,
    required this.viewedAt,
    required this.lastPage,
  });
}

class RemoteMediaApiClient {
  final String baseUrl;
  final String? authToken;
  final Duration timeout;
  final Duration uploadTimeout;

  const RemoteMediaApiClient({
    required this.baseUrl,
    this.authToken,
    this.timeout = const Duration(seconds: 15),
    this.uploadTimeout = const Duration(minutes: 10),
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
      pageCount: _asInt(json['pageCount']),
    );
  }

  Future<List<RemoteMediaActivityEntry>> fetchRecentMediaActivity({
    int limit = 24,
  }) async {
    final json = await _getJson(
      '/activity/recent',
      queryParameters: <String, String>{'limit': '${limit < 1 ? 1 : limit}'},
    );
    final rows = _unwrapList(json, preferredKeys: const ['items', 'results']);
    return rows
        .whereType<Map>()
        .map((row) => _parseMediaActivityEntry(Map<String, dynamic>.from(row)))
        .toList(growable: false);
  }

  Future<ReadingProgressEntry?> fetchReadingProgress(String mediaId) async {
    try {
      final json = await _getJson('/progress/${Uri.encodeComponent(mediaId)}');
      if (json is! Map<String, dynamic>) {
        throw const RemoteMediaException('読書進捗の形式が不正です');
      }
      return _parseReadingProgressEntry(json);
    } on RemoteMediaException catch (error) {
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
    final rows = _unwrapList(json, preferredKeys: const ['items', 'results']);
    return rows
        .whereType<Map>()
        .map((row) => _parseReadingProgressEntry(Map<String, dynamic>.from(row)))
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
    final jsonBody = await _sendJsonRequest(
      'PUT',
      '/progress/${Uri.encodeComponent(mediaId)}',
      body: <String, dynamic>{
        'currentPage': currentPage,
        if (totalPages != null) 'totalPages': totalPages,
        if (progress != null) 'progress': progress,
        if (lastReadAt != null) 'lastReadAt': lastReadAt.toUtc().toIso8601String(),
        if (updatedAt != null) 'updatedAt': updatedAt.toUtc().toIso8601String(),
        if (identity != null) 'identity': identity,
      },
    );
    if (jsonBody is! Map<String, dynamic>) {
      throw const RemoteMediaException('読書進捗の形式が不正です');
    }
    return _parseReadingProgressEntry(jsonBody);
  }

  Future<RemoteMediaActivityEntry> recordMediaActivity(
    String mediaId, {
    ResolvedMediaIdentity? identity,
    int? lastPage,
    int? totalPages,
  }) async {
    final jsonBody = await _sendJsonRequest(
      'POST',
      '/media/${Uri.encodeComponent(mediaId)}/activity',
      body: <String, dynamic>{
        if (identity != null) 'identity': identity.toJson(),
        if (lastPage != null) 'lastPage': lastPage,
        if (totalPages != null) 'totalPages': totalPages,
      },
    );
    if (jsonBody is! Map<String, dynamic>) {
      throw const RemoteMediaException('閲覧履歴の形式が不正です');
    }
    return _parseMediaActivityEntry(jsonBody);
  }

  Future<void> renameMedia({
    required MediaItem beforeItem,
    required MediaItem afterItem,
    required ResolvedMediaIdentity beforeIdentity,
  }) async {
    await _sendJsonRequest(
      'POST',
      '/rename',
      body: <String, dynamic>{
        'oldPath': beforeItem.id,
        'newPath': afterItem.id,
        'before': <String, dynamic>{
          ...beforeIdentity.toJson(),
          'path': beforeItem.id,
          'folderRaw': beforeItem.folderRaw,
          'displayName': beforeItem.displayName,
        },
        'after': <String, dynamic>{
          'path': afterItem.id,
          'folderRaw': afterItem.folderRaw,
          'displayName': afterItem.displayName,
        },
      },
    );
  }

  Future<void> deleteMedia(
    List<(MediaItem, ResolvedMediaIdentity)> items, {
    required bool hardDelete,
  }) async {
    await _sendJsonRequest(
      'POST',
      '/delete',
      body: <String, dynamic>{
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
        final payload = await response
            .transform(const Utf8Decoder(allowMalformed: true))
            .join();
        final jsonBody = payload.trim().isEmpty
            ? null
            : _tryDecodeJson(payload);
        throw RemoteMediaException(
          _extractErrorMessage(jsonBody) ??
              _messageForStatus(response.statusCode),
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
      rejectThumbnailPlaceholder: true,
    );
  }

  Future<Uint8List> fetchPageImage(
    String mediaId,
    int pageNo, {
    int? width,
  }) async {
    return _getBytes(
      '/media/${Uri.encodeComponent(mediaId)}/page/$pageNo',
      queryParameters: <String, String>{if (width != null) 'width': '$width'},
      rejectThumbnailPlaceholder: true,
    );
  }

  Future<RemoteUploadResponse> uploadFiles({
    required String folderRaw,
    required List<RemoteUploadFile> files,
    ImportMetadata? importMetadata,
    bool skipIfExists = true,
    void Function(MediaTransferProgress progress)? onProgress,
    String? requestId,
  }) async {
    final traceId = _normalizeUploadRequestId(requestId);
    if (files.isEmpty) {
      return RemoteUploadResponse(
        importedCount: 0,
        skippedCount: 0,
        requestId: traceId,
      );
    }

    final uri = _buildUri('/upload');
    final client = HttpClient()
      ..connectionTimeout = uploadTimeout
      ..idleTimeout = uploadTimeout;

    final boundary = '----pdf-viewer-${DateTime.now().millisecondsSinceEpoch}';
    final totalBytes = files.fold<int>(
      0,
      (sum, file) => sum + file.bytes.length,
    );
    var sentBytes = 0;
    var completedFiles = 0;
    const chunkSize = 256 * 1024;

    final trimmedArtistTag = importMetadata?.artistTag?.trim();
    final trimmedSeriesTag = importMetadata?.seriesTag?.trim();
    final trimmedTargetCollection = importMetadata?.targetCollection?.trim();
    final trimmedHostPdfFileNameHint =
        importMetadata?.hostPdfFileNameHint?.trim();
    final artistTag = trimmedArtistTag != null && trimmedArtistTag.isNotEmpty
        ? trimmedArtistTag
        : null;
    final seriesTag = trimmedSeriesTag != null && trimmedSeriesTag.isNotEmpty
        ? trimmedSeriesTag
        : null;
    final targetCollection =
        trimmedTargetCollection != null && trimmedTargetCollection.isNotEmpty
        ? trimmedTargetCollection
        : null;
    final hostPdfFileNameHint =
        trimmedHostPdfFileNameHint != null &&
            trimmedHostPdfFileNameHint.isNotEmpty
        ? trimmedHostPdfFileNameHint
        : null;
    final freeTags =
        importMetadata?.freeTags
            .map((entry) => entry.trim())
            .where((entry) => entry.isNotEmpty)
            .toList(growable: false) ??
        const <String>[];
    final characterTags =
        importMetadata?.characterTags
            .map((entry) => entry.trim())
            .where((entry) => entry.isNotEmpty)
            .toList(growable: false) ??
        const <String>[];
    final organizeAfterImport = importMetadata?.organizeAfterImport ?? false;
    final convertToPdfOnHost = importMetadata?.convertToPdfOnHost ?? false;
    final originalDisplayNamesJson = jsonEncode(
      files.map((file) => file.fileName).toList(growable: false),
    );
    final sourceRelativePaths = files
        .map((file) => file.sourceRelativePath?.trim() ?? '')
        .toList(growable: false);
    final hasSourceRelativePaths = sourceRelativePaths.any(
      (entry) => entry.isNotEmpty,
    );
    final sourceRelativePathsJson = hasSourceRelativePaths
        ? jsonEncode(sourceRelativePaths)
        : null;
    final serializedFileTagGroups = files
        .map((file) => file.tags.map(_tagToJson).toList(growable: false))
        .toList(growable: false);
    final hasFileTags = serializedFileTagGroups.any(
      (group) => group.isNotEmpty,
    );
    final fileTagsJson = hasFileTags
        ? jsonEncode(serializedFileTagGroups)
        : null;
    final freeTagsJson = freeTags.isNotEmpty ? jsonEncode(freeTags) : null;
    final characterTagsJson = characterTags.isNotEmpty
        ? jsonEncode(characterTags)
        : null;

    debugPrint(
      '[UPLOAD][CLIENT][req:$traceId] start '
      'targetFolderId=${_debugUploadString(folderRaw)} '
      'fileNames=${_debugUploadStringList(files.map((file) => file.fileName))} '
      'targetCollection=${_debugUploadString(targetCollection)} '
      'convertToPdfOnHost=$convertToPdfOnHost '
      'organizeAfterImport=$organizeAfterImport '
      'sourceRelativePathsJsonPresent=$hasSourceRelativePaths',
    );
    debugPrint(
      '[TAG][CLIENT][req:$traceId] metadata '
      'artist=${_debugUploadString(artistTag)} '
      'series=${_debugUploadString(seriesTag)} '
      'character=${_debugUploadStringList(characterTags)} '
      'free=${_debugUploadStringList(freeTags)}',
    );
    debugPrint(
      '[UPLOAD][CLIENT][req:$traceId] payload summary '
      'fileCount=${files.length} '
      'fileTagsPresent=$hasFileTags '
      'sourceRelativePathsJson=${sourceRelativePathsJson ?? 'null'} '
      'fileTagsJson=${fileTagsJson ?? 'null'}',
    );
    debugPrint(
      '[TAG][CLIENT][req:$traceId] serialized '
      'artistTag=${_debugUploadString(artistTag)} '
      'seriesTag=${_debugUploadString(seriesTag)} '
      'characterTagsJson=${characterTagsJson ?? 'null'} '
      'freeTagsJson=${freeTagsJson ?? 'null'} '
      'targetCollection=${_debugUploadString(targetCollection)} '
      'organizeAfterImport=$organizeAfterImport',
    );

    try {
      debugPrint(
        '[UPLOAD][CLIENT][req:$traceId] POST /upload '
        'folder=${_debugUploadString(folderRaw)} files=${files.length}',
      );
      final request = await client.postUrl(uri);
      _applyHeaders(request.headers);
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

      writeField('uploadRequestId', traceId);
      writeField('folderRaw', folderRaw);
      writeField('skipIfExists', skipIfExists ? 'true' : 'false');
      writeField('originalDisplayNamesJson', originalDisplayNamesJson);
      if (sourceRelativePathsJson != null) {
        writeField('sourceRelativePathsJson', sourceRelativePathsJson);
      }
      if (fileTagsJson != null) {
        writeField('fileTagsJson', fileTagsJson);
      }
      if (artistTag != null) {
        writeField('artistTag', artistTag);
      }
      if (seriesTag != null) {
        writeField('seriesTag', seriesTag);
      }
      if (freeTagsJson != null) {
        writeField('freeTagsJson', freeTagsJson);
      }
      if (characterTagsJson != null) {
        writeField('characterTagsJson', characterTagsJson);
      }
      if (targetCollection != null) {
        writeField('targetCollection', targetCollection);
      }
      if (importMetadata != null) {
        writeField(
          'convertToPdfOnHost',
          convertToPdfOnHost ? 'true' : 'false',
        );
        if (hostPdfFileNameHint != null) {
          writeField('hostPdfNameHint', hostPdfFileNameHint);
        }
        writeField(
          'organizeAfterImport',
          organizeAfterImport ? 'true' : 'false',
        );
      }
      debugPrint(
        '[UPLOAD][CLIENT][req:$traceId] multipart '
        'uploadRequestId=${_debugUploadString(traceId)} '
        'folderRaw=${_debugUploadString(folderRaw)} '
        'skipIfExists=$skipIfExists '
        'originalDisplayNamesJson=$originalDisplayNamesJson '
        'sourceRelativePathsJson=${sourceRelativePathsJson ?? 'null'} '
        'fileTagsJson=${fileTagsJson ?? 'null'} '
        'artistTag=${_debugUploadString(artistTag)} '
        'seriesTag=${_debugUploadString(seriesTag)} '
        'characterTagsJson=${characterTagsJson ?? 'null'} '
        'freeTagsJson=${freeTagsJson ?? 'null'} '
        'targetCollection=${_debugUploadString(targetCollection)} '
        'convertToPdfOnHost=$convertToPdfOnHost '
        'hostPdfFileNameHint=${_debugUploadString(hostPdfFileNameHint)} '
        'organizeAfterImport=$organizeAfterImport',
      );

      onProgress?.call(
        MediaTransferProgress(
          sentBytes: 0,
          totalBytes: totalBytes,
          completedFiles: 0,
          totalFiles: files.length,
          statusLabel: '??????????????',
        ),
      );

      for (var index = 0; index < files.length; index++) {
        final file = files[index];
        final multipartFileName = _safeMultipartFileName(file.fileName, index);
        debugPrint(
          '[UPLOAD][CLIENT][req:$traceId] multipart file '
          'index=$index multipartName=$multipartFileName '
          'originalDisplayName=${_debugUploadString(file.fileName)} '
          'sourceRelativePath=${_debugUploadString(file.sourceRelativePath)} '
          'tags=${_formatClientTagList(file.tags)} '
          'originalUtf8=${_utf8HexPreview(file.fileName)}',
        );
        writeAscii('--$boundary\r\n');
        writeAscii(
          'Content-Disposition: form-data; name="files"; '
          'filename="${_escapeQuoted(multipartFileName)}"\r\n',
        );
        writeAscii('Content-Type: ${file.mimeType}\r\n\r\n');
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
              statusLabel: '???????????????',
            ),
          );
        }
        writeAscii('\r\n');

        completedFiles++;
        onProgress?.call(
          MediaTransferProgress(
            sentBytes: sentBytes,
            totalBytes: totalBytes,
            completedFiles: completedFiles,
            totalFiles: files.length,
            currentFileName: file.fileName,
            statusLabel: '????????????????????',
          ),
        );
      }

      writeAscii('--$boundary--\r\n');
      onProgress?.call(
        MediaTransferProgress(
          sentBytes: sentBytes,
          totalBytes: totalBytes,
          completedFiles: completedFiles,
          totalFiles: files.length,
          statusLabel: '??????????????',
        ),
      );

      final response = await request.close().timeout(uploadTimeout);
      final payload = await response
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(uploadTimeout);
      final jsonBody = payload.trim().isEmpty ? null : _tryDecodeJson(payload);
      debugPrint(
        '[UPLOAD][CLIENT][req:$traceId] response '
        'status=${response.statusCode} body=${payload.trim().isEmpty ? '""' : payload}',
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw RemoteMediaException(
          _extractErrorMessage(jsonBody) ??
              _messageForStatus(response.statusCode),
          statusCode: response.statusCode,
        );
      }

      if (jsonBody is! Map<String, dynamic>) {
        return RemoteUploadResponse(
          importedCount: files.length,
          skippedCount: 0,
          requestId: traceId,
        );
      }

      onProgress?.call(
        MediaTransferProgress(
          sentBytes: totalBytes,
          totalBytes: totalBytes,
          completedFiles: files.length,
          totalFiles: files.length,
          statusLabel: '?????????????',
        ),
      );
      final parsedResponse = RemoteUploadResponse(
        importedCount:
            _asInt(jsonBody['importedCount']) ??
            _asInt(jsonBody['count']) ??
            files.length,
        skippedCount: _asInt(jsonBody['skippedCount']) ?? 0,
        taggedCount: _asInt(jsonBody['taggedCount']) ?? 0,
        organizedCount: _asInt(jsonBody['organizedCount']) ?? 0,
        rescannedCount: _asInt(jsonBody['rescannedCount']) ?? 0,
        requestId: jsonBody['requestId']?.toString() ?? traceId,
        tagAttachSuccessCount: _asInt(jsonBody['tagAttachSuccessCount']) ?? 0,
        tagAttachFailureCount: _asInt(jsonBody['tagAttachFailureCount']) ?? 0,
        attachedTagsByMedia: _parseAttachedTagsByMedia(
          jsonBody['attachedTagsByMedia'],
        ),
      );
      debugPrint(
        '[UPLOAD][RESULT][req:$traceId] '
        'responseRequestId=${_debugUploadString(parsedResponse.requestId)} '
        'imported=${parsedResponse.importedCount} '
        'skipped=${parsedResponse.skippedCount} '
        'tagged=${parsedResponse.taggedCount} '
        'organized=${parsedResponse.organizedCount} '
        'rescanned=${parsedResponse.rescannedCount} '
        'tagAttachSuccess=${parsedResponse.tagAttachSuccessCount} '
        'tagAttachFailure=${parsedResponse.tagAttachFailureCount} '
        'attachedTagsByMedia=${_formatAttachedTagsByMedia(parsedResponse.attachedTagsByMedia)}',
      );
      return parsedResponse;
    } on TimeoutException catch (error, stackTrace) {
      debugPrint('[UPLOAD][ERROR][req:$traceId] timeout error=$error');
      debugPrintStack(
        label: '[UPLOAD][ERROR][req:$traceId] timeout stack',
        stackTrace: stackTrace,
      );
      throw RemoteMediaException(
        '????????????????????'
        '??????????????????????????????',
      );
    } on SocketException catch (error, stackTrace) {
      debugPrint('[UPLOAD][ERROR][req:$traceId] socket error=$error');
      debugPrintStack(
        label: '[UPLOAD][ERROR][req:$traceId] socket stack',
        stackTrace: stackTrace,
      );
      throw const RemoteMediaException('????????????');
    } catch (error, stackTrace) {
      debugPrint('[UPLOAD][ERROR][req:$traceId] unexpected error=$error');
      debugPrintStack(
        label: '[UPLOAD][ERROR][req:$traceId] unexpected stack',
        stackTrace: stackTrace,
      );
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  Future<UrlImportResult> downloadUrl({
    required String folderRaw,
    required String sourceUrl,
    ImportMetadata? importMetadata,
    UrlImportOptions? options,
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

    final jsonBody = await _sendJsonRequest(
      'POST',
      '/download-url',
      requestTimeout: uploadTimeout,
      body: <String, dynamic>{
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
        if (artistTag != null && artistTag.isNotEmpty) 'artistTag': artistTag,
        if (seriesTag != null && seriesTag.isNotEmpty) 'seriesTag': seriesTag,
        if (importMetadata != null && importMetadata.freeTags.isNotEmpty)
          'freeTags': importMetadata.freeTags,
        if (importMetadata != null && importMetadata.characterTags.isNotEmpty)
          'characterTags': importMetadata.characterTags,
        if (targetCollection != null && targetCollection.isNotEmpty)
          'targetCollection': targetCollection,
        'organizeAfterImport': importMetadata?.organizeAfterImport ?? false,
      },
    );

    if (jsonBody is! Map<String, dynamic>) {
      return const UrlImportResult(importedCount: 0);
    }

    return UrlImportResult(
      importedCount: _asInt(jsonBody['importedCount']) ?? 0,
      skippedCount: _asInt(jsonBody['skippedCount']) ?? 0,
      failedCount: _asInt(jsonBody['failedCount']) ?? 0,
    );
  }

  Future<dynamic> _getJson(
    String path, {
    Map<String, String>? queryParameters,
  }) async {
    final bytes = await _getBytes(path, queryParameters: queryParameters);
    final raw = utf8.decode(bytes, allowMalformed: true);
    if (raw.trim().isEmpty) {
      return <String, dynamic>{};
    }
    return jsonDecode(raw);
  }

  Future<dynamic> _sendJsonRequest(
    String method,
    String path, {
    Map<String, String>? queryParameters,
    Map<String, dynamic>? body,
    Duration? requestTimeout,
  }) async {
    final uri = _buildUri(path, queryParameters: queryParameters);
    final effectiveTimeout = requestTimeout ?? timeout;
    final client = HttpClient()
      ..connectionTimeout = effectiveTimeout
      ..idleTimeout = effectiveTimeout;

    try {
      final request = await _openRequest(client, method, uri);
      request.headers.contentType = ContentType.json;
      _applyHeaders(request.headers);
      if (body != null) {
        request.write(jsonEncode(body));
      }

      final response = await request.close().timeout(effectiveTimeout);
      final payload = await response
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(effectiveTimeout);
      final jsonBody = payload.trim().isEmpty ? null : _tryDecodeJson(payload);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw RemoteMediaException(
          _extractErrorMessage(jsonBody) ??
              _messageForStatus(response.statusCode),
          statusCode: response.statusCode,
        );
      }

      return jsonBody ?? <String, dynamic>{};
    } on TimeoutException {
      throw const RemoteMediaException('サーバー応答がタイムアウトしました');
    } on SocketException {
      throw const RemoteMediaException('サーバーに接続できません');
    } finally {
      client.close(force: true);
    }
  }

  Future<Uint8List> _getBytes(
    String path, {
    Map<String, String>? queryParameters,
    bool rejectThumbnailPlaceholder = false,
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
          _extractErrorMessage(jsonBody) ??
              _messageForStatus(response.statusCode),
          statusCode: response.statusCode,
        );
      }

      final thumbnailStatus = response.headers
          .value('x-thumbnail-status')
          ?.trim()
          .toLowerCase();
      if (rejectThumbnailPlaceholder && thumbnailStatus == 'placeholder') {
        final detail = response.headers.value('x-thumbnail-detail')?.trim();
        throw RemoteMediaException(
          detail == null || detail.isEmpty
              ? 'Thumbnail placeholder returned'
              : detail,
          statusCode: 503,
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

  Uri _buildUri(String path, {Map<String, String>? queryParameters}) {
    final baseUri = _parseBaseUri();
    return baseUri.replace(
      path: _joinPath(baseUri.path, path),
      queryParameters: queryParameters?.isEmpty == true
          ? null
          : queryParameters,
    );
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

  String _normalizeMultipartFileName(String value) {
    var normalized = value.trim();
    if (ImportSourceNormalizer.looksLikeEncodedCollection(normalized) ||
        normalized.contains('/') ||
        normalized.contains('\\')) {
      normalized = ImportSourceNormalizer.basenameFromPathish(normalized);
    }
    normalized = normalized
        .replaceAll(RegExp(r'[<>:\"/\\|?*\x00-\x1F]+'), '_')
        .replaceAll(RegExp(r'[\r\n]+'), ' ')
        .trim();
    while (normalized.endsWith('.') || normalized.endsWith(' ')) {
      normalized = normalized.substring(0, normalized.length - 1).trimRight();
    }
    return normalized.isEmpty ? 'upload.bin' : normalized;
  }

  String _safeMultipartFileName(String originalDisplayName, int index) {
    final normalized = _normalizeMultipartFileName(originalDisplayName);
    final ext = _asciiSafeExtension(normalized);
    final hash = _shortAsciiHash(normalized);
    final order = (index + 1).toString().padLeft(3, '0');
    return 'upload_${order}_$hash$ext';
  }

  String _asciiSafeExtension(String value) {
    final dotIndex = value.lastIndexOf('.');
    if (dotIndex <= 0 || dotIndex >= value.length - 1) {
      return '';
    }
    final ext = value.substring(dotIndex).toLowerCase();
    final sanitized = ext.replaceAll(RegExp(r'[^a-z0-9.]'), '');
    if (sanitized.isEmpty || !sanitized.startsWith('.')) {
      return '';
    }
    return sanitized;
  }

  String _shortAsciiHash(String value) {
    var hash = 0x811C9DC5;
    const prime = 0x01000193;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * prime) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  Map<String, dynamic> _tagToJson(Tag tag) {
    return <String, dynamic>{'name': tag.name, 'category': tag.category.name};
  }

  RemoteMediaActivityEntry _parseMediaActivityEntry(Map<String, dynamic> json) {
    final viewedAt =
        _parseDateTime(json['viewedAt']?.toString()) ?? DateTime.now();
    final rawLastPage = _asInt(json['lastPage']);
    return RemoteMediaActivityEntry(
      mediaId: json['mediaId']?.toString().trim() ?? '',
      folderRaw: json['folderRaw']?.toString().trim() ?? '',
      viewedAt: viewedAt,
      lastPage: rawLastPage != null && rawLastPage > 0 ? rawLastPage : null,
    );
  }

  ReadingProgressEntry _parseReadingProgressEntry(Map<String, dynamic> json) {
    final currentPage =
        (_asInt(json['currentPage']) ?? 1).clamp(1, 1 << 30) as int;
    final totalPages = _asInt(json['totalPages']);
    final lastReadAt =
        _parseDateTime(json['lastReadAt']?.toString()) ?? DateTime.now();
    final updatedAt =
        _parseDateTime(json['updatedAt']?.toString()) ?? lastReadAt;
    return ReadingProgressEntry(
      mediaId: json['mediaId']?.toString().trim() ?? '',
      title: json['title']?.toString().trim() ?? '',
      folderRaw: json['folderRaw']?.toString().trim() ?? '',
      currentPage: currentPage,
      totalPages: totalPages != null && totalPages > 0 ? totalPages : null,
      progress: ((_asDouble(json['progress']) ?? 0.0).clamp(0.0, 1.0) as num)
          .toDouble(),
      lastReadAt: lastReadAt,
      updatedAt: updatedAt,
      thumbnailUrl: json['thumbnailUrl']?.toString(),
    );
  }

  String _normalizeUploadRequestId(String? raw) {
    final trimmed = raw?.trim() ?? '';
    if (trimmed.isNotEmpty) {
      return trimmed;
    }
    final micros = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final hash = _fnv1a32Hex('$baseUrl|$micros');
    return 'up-$micros-${hash.substring(0, 6)}';
  }

  String _fnv1a32Hex(String value) {
    var hash = 0x811C9DC5;
    const prime = 0x01000193;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * prime) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  String _debugUploadString(String? value) {
    if (value == null) {
      return 'null';
    }
    return jsonEncode(value);
  }

  String _debugUploadStringList(Iterable<String> values) {
    final list = values.toList(growable: false);
    if (list.isEmpty) {
      return '[]';
    }
    return '[${list.map(_debugUploadString).join(', ')}]';
  }

  String _formatClientTagList(Iterable<Tag> tags) {
    final values = tags
        .map((tag) => '${tag.category.name}:${tag.name.trim()}')
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false);
    return _debugUploadStringList(values);
  }

  List<RemoteUploadedMediaTags> _parseAttachedTagsByMedia(dynamic raw) {
    if (raw is! Map) {
      return const <RemoteUploadedMediaTags>[];
    }
    final items = <RemoteUploadedMediaTags>[];
    for (final entry in raw.entries) {
      final mediaId = entry.key.toString();
      final values = entry.value is List
          ? (entry.value as List)
                .map((item) => item.toString())
                .toList(growable: false)
          : const <String>[];
      items.add(RemoteUploadedMediaTags(mediaId: mediaId, tags: values));
    }
    return items;
  }

  String _formatAttachedTagsByMedia(List<RemoteUploadedMediaTags> items) {
    if (items.isEmpty) {
      return '[]';
    }
    final values = items
        .map(
          (item) =>
              '{mediaId:${_debugUploadString(item.mediaId)}, tags:${_debugUploadStringList(item.tags)}}',
        )
        .toList(growable: false);
    return '[${values.join(', ')}]';
  }

  String _utf8HexPreview(String value) {
    final bytes = utf8.encode(value);
    final preview = bytes
        .take(32)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return bytes.length > 32 ? '$preview...' : preview;
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

  double? _asDouble(dynamic raw) {
    if (raw == null) {
      return null;
    }
    if (raw is num) {
      return raw.toDouble();
    }
    return double.tryParse(raw.toString());
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
