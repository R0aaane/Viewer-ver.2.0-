import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  const LocalUrlDownloadResult({
    required this.importedCount,
    this.skippedCount = 0,
    this.failedCount = 0,
    this.logLines = const <String>[],
  });
}

class UrlImportDownloaderService {
  static const String _uiEventPrefix = '__KEMONO_DL_UI__';

  Future<LocalUrlDownloadResult> downloadUrl({
    required String sourceUrl,
    required String destinationFolder,
    UrlImportOptions? options,
    void Function(MediaTransferProgress progress)? onProgress,
  }) async {
    final launchers = <String>['python', 'py'];
    Object? lastError;

    for (final launcher in launchers) {
      try {
        return await _runWithLauncher(
          launcher: launcher,
          sourceUrl: sourceUrl,
          destinationFolder: destinationFolder,
          options: options,
          onProgress: onProgress,
        );
      } on ProcessException catch (error) {
        lastError = error;
      } on UrlImportDownloaderException catch (error) {
        lastError = error;
        if (!_looksLikeMissingLauncher(error.message)) {
          rethrow;
        }
      }
    }

    throw UrlImportDownloaderException(
      lastError?.toString() ?? 'Python ランチャーが見つかりませんでした',
    );
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
    var sawEvent = false;

    void appendLog(String line) {
      logLines.add(line);
      while (logLines.length > 80) {
        logLines.removeAt(0);
      }
    }

    Future<void> consumeStdout() async {
      await for (final line in process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())) {
        if (line.startsWith(_uiEventPrefix)) {
          sawEvent = true;
          final payload = line.substring(_uiEventPrefix.length);
          try {
            final event = jsonDecode(payload);
            if (event is Map<String, dynamic>) {
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
      await for (final line in process.stderr
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
      throw const UrlImportDownloaderException(
        'ダウンローダーから進捗応答を受け取れませんでした',
      );
    }

    return LocalUrlDownloadResult(
      importedCount: importedCount,
      skippedCount: skippedCount,
      failedCount: failedCount,
      logLines: logLines,
    );
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
      args..add('--url')..add(url);
    }

    final cookieFilePath = options.normalizedCookieFilePath;
    if (cookieFilePath != null) {
      args..add('--cookies')..add(cookieFilePath);
    }

    args
      ..add('--cookie-mode')
      ..add(options.cookieMode.apiValue);

    final urlListFilePath = options.normalizedUrlListFilePath;
    if (urlListFilePath != null) {
      args..add('--from-file')..add(urlListFilePath);
    }

    final sites = options.normalizedFavoriteSites;
    if (sites.isNotEmpty) {
      args..add('--sites')..add(sites.join(','));
    }
    if (options.favoritePosts) {
      args.add('--fav-posts');
    }

    final favoriteUserServices = options.normalizedFavoriteUserServices;
    if (favoriteUserServices.isNotEmpty) {
      args..add('--fav-users')..add(favoriteUserServices.join(','));
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
}







