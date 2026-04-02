import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

class UrlImportDownloaderService {
  static const String _uiEventPrefix = '__KEMONO_DL_UI__';
  static const String _contentDispositionHeader = 'content-disposition';

  Future<LocalUrlDownloadResult> downloadUrl({
    required String sourceUrl,
    required String destinationFolder,
    UrlImportOptions? options,
    void Function(MediaTransferProgress progress)? onProgress,
  }) async {
    final effectiveOptions = options ?? const UrlImportOptions();

    if (_canUseLauncherFlow) {
      final launchers = <String>['python', 'py'];
      for (final launcher in launchers) {
        try {
          return await _runWithLauncher(
            launcher: launcher,
            sourceUrl: sourceUrl,
            destinationFolder: destinationFolder,
            options: effectiveOptions,
            onProgress: onProgress,
          );
        } on ProcessException catch (error) {
          stderr.writeln(
            '[url-import] launcher unavailable: $launcher ($error)',
          );
        } on UrlImportDownloaderException catch (error) {
          if (!_looksLikeMissingLauncher(error.message)) {
            rethrow;
          }
          stderr.writeln(
            '[url-import] launcher fallback: $launcher (${error.message})',
          );
        }
      }
    }

    return _runDirectUrlDownload(
      sourceUrl: sourceUrl,
      destinationFolder: destinationFolder,
      options: effectiveOptions,
      onProgress: onProgress,
    );
  }

  bool get _canUseLauncherFlow => !Platform.isAndroid && !Platform.isIOS;

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
    var sawEvent = false;
    final hitomiMetadataByRelativePath = <String, HitomiGalleryMetadata>{};

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

    final urls = await _collectDirectUrls(sourceUrl, options);
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
        request.headers.set(
          HttpHeaders.userAgentHeader,
          'pdf_viewer/standalone',
        );

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
        try {
          fileName = _buildDownloadFileName(
            uri,
            response,
            sequence: importedCount + skippedCount + failedCount + 1,
          );
        } on UrlImportDownloaderException catch (error) {
          failedCount++;
          appendLog('[error] ${error.message}: $rawUrl');
          await response.drain<void>();
          continue;
        }

        final targetPath = p.join(destinationDir.path, fileName);
        final targetFile = File(targetPath);
        if (await targetFile.exists() && !options.overwriteExistingFiles) {
          skippedCount++;
          appendLog('[skip] exists: $fileName');
          await response.drain<void>();
          continue;
        }

        IOSink? sink;
        try {
          sink = targetFile.openWrite();
          await response.forEach(sink.add);
          await sink.flush();
          await sink.close();
          importedCount++;
          appendLog('[ok] $rawUrl -> $fileName');
        } catch (error) {
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
    );
  }

  Future<List<String>> _collectDirectUrls(
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

  String _buildDownloadFileName(
    Uri uri,
    HttpClientResponse response, {
    required int sequence,
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
    if (fileName == null) {
      fileName = 'download_$sequence${inferredExtension ?? ''}';
    }

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
