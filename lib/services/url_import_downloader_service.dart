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

class _PreparedUrlImportSources {
  final List<String> launcherUrls;
  final List<String> directUrls;

  const _PreparedUrlImportSources({
    this.launcherUrls = const <String>[],
    this.directUrls = const <String>[],
  });

  bool get hasLauncherUrls => launcherUrls.isNotEmpty;
  bool get hasDirectUrls => directUrls.isNotEmpty;
  bool get isEmpty => launcherUrls.isEmpty && directUrls.isEmpty;
}

class UrlImportDownloaderService {
  static const String _uiEventPrefix = '__KEMONO_DL_UI__';
  static const String _contentDispositionHeader = 'content-disposition';
  static const String _standaloneUserAgent = 'pdf_viewer/standalone';
  static const String _dddSmartHost = 'ddd-smart.net';
  static const String _dddSmartCdnHost = 'cdn.ddd-smart.net';
  static const Set<String> _launcherSupportedHitomiSegments = <String>{
    'manga',
    'doujinshi',
    'cg',
    'gamecg',
    'imageset',
    'galleries',
    'reader',
  };

  Future<LocalUrlDownloadResult> downloadUrl({
    required String sourceUrl,
    required String destinationFolder,
    UrlImportOptions? options,
    void Function(MediaTransferProgress progress)? onProgress,
  }) async {
    final effectiveOptions = options ?? const UrlImportOptions();
    final prepared = await _prepareImportSources(sourceUrl, effectiveOptions);

    if (prepared.isEmpty && !effectiveOptions.hasFavoriteTargets) {
      /* throw const UrlImportDownloaderException(
        '逶ｴ謗･繝繧ｦ繝ｳ繝ｭ繝ｼ繝峨〒縺阪ｋ URL 縺瑚ｦ九▽縺九ｊ縺ｾ縺帙ｓ縺ｧ縺励◆',
      ); */
      /* throw const UrlImportDownloaderException(
        'Direct download does not support favorites import',
      ); */
      throw const UrlImportDownloaderException(
        'No downloadable URLs were found',
      );
    }

    final launcherOptions = _copyOptionsWithoutUrlListFile(effectiveOptions);
    final directOptions = _copyOptionsForDirectDownload(effectiveOptions);
    final pendingDirectUrls = <String>[...prepared.directUrls];
    final results = <LocalUrlDownloadResult>[];
    UrlImportDownloaderException? lastLauncherMissingError;

    Future<void> runDirectUrls() async {
      if (pendingDirectUrls.isEmpty) {
        return;
      }
      final completedOffset = _totalHandledFiles(results);
      final result = await _runDirectUrlDownloadUrls(
        urls: pendingDirectUrls,
        destinationFolder: destinationFolder,
        options: directOptions,
        onProgress: _withProgressOffset(
          onProgress,
          completedOffset: completedOffset,
          trailingFiles: 0,
        ),
      );
      results.add(result);
    }

    final needsLauncherWork =
        effectiveOptions.hasFavoriteTargets || prepared.hasLauncherUrls;
    if (needsLauncherWork && _canUseLauncherFlow) {
      final launcherSourceUrl = prepared.launcherUrls.join('\n');
      final launchers = <String>['python', 'py'];
      for (final launcher in launchers) {
        try {
          final completedOffset = _totalHandledFiles(results);
          final result = await _runWithLauncher(
            launcher: launcher,
            sourceUrl: launcherSourceUrl,
            destinationFolder: destinationFolder,
            options: launcherOptions,
            onProgress: _withProgressOffset(
              onProgress,
              completedOffset: completedOffset,
              trailingFiles: pendingDirectUrls.length,
            ),
          );
          results.add(result);
          await runDirectUrls();
          return _mergeDownloadResults(results);
        } on ProcessException catch (error) {
          stderr.writeln(
            '[url-import] launcher unavailable: $launcher ($error)',
          );
          lastLauncherMissingError = UrlImportDownloaderException(
            error.toString(),
          );
        } on UrlImportDownloaderException catch (error) {
          if (!_looksLikeMissingLauncher(error.message)) {
            rethrow;
          }
          stderr.writeln(
            '[url-import] launcher fallback: $launcher (${error.message})',
          );
          lastLauncherMissingError = error;
        }
      }
    }

    if (effectiveOptions.hasFavoriteTargets) {
      throw lastLauncherMissingError ??
          const UrlImportDownloaderException(
            'favorites 蜿門ｾ励↓縺ｯ Python 繝ｩ繝ｳ繝√Ε繝ｼ繧帝K霈峨〒縺阪∪縺帙ｓ',
          );
    }

    if (prepared.hasLauncherUrls) {
      pendingDirectUrls.insertAll(0, prepared.launcherUrls);
    }
    await runDirectUrls();
    return _mergeDownloadResults(results);
  }

  bool get _canUseLauncherFlow => !Platform.isAndroid && !Platform.isIOS;

  Future<_PreparedUrlImportSources> _prepareImportSources(
    String sourceUrl,
    UrlImportOptions options,
  ) async {
    final launcherUrls = <String>[];
    final directUrls = <String>[];
    final launcherSeen = <String>{};
    final directSeen = <String>{};

    for (final rawUrl in await _collectInputUrls(sourceUrl, options)) {
      final resolvedDirectUrl = await _resolveSpecialDirectUrl(rawUrl);
      if (resolvedDirectUrl != null) {
        if (directSeen.add(resolvedDirectUrl)) {
          directUrls.add(resolvedDirectUrl);
        }
        continue;
      }

      if (_supportsLauncherUrl(rawUrl)) {
        if (launcherSeen.add(rawUrl)) {
          launcherUrls.add(rawUrl);
        }
      } else if (directSeen.add(rawUrl)) {
        directUrls.add(rawUrl);
      }
    }

    return _PreparedUrlImportSources(
      launcherUrls: launcherUrls,
      directUrls: directUrls,
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

  // ignore: unused_element
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

    final prepared = await _prepareImportSources(sourceUrl, options);
    final urls = <String>[...prepared.directUrls, ...prepared.launcherUrls];
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
            currentFileName: rawUrl, /*
            statusLabel: 'URL からダウンロードしています',
            */
            statusLabel: 'Downloading URL',
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
        request.headers.set(HttpHeaders.userAgentHeader, _standaloneUserAgent);

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
            currentFileName: fileName, /*
            statusLabel: 'URL ダウンロードを処理しています',
            */
            statusLabel: 'Saved URL file',
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

  Future<LocalUrlDownloadResult> _runDirectUrlDownloadUrls({
    required List<String> urls,
    required String destinationFolder,
    required UrlImportOptions options,
    void Function(MediaTransferProgress progress)? onProgress,
  }) async {
    if (options.hasFavoriteTargets) {
      /* throw const UrlImportDownloaderException(
        '縺薙・迺ｰ蠅・・繧ｹ繧ｿ繝ｳ繝峨い繝ｭ繝ｳ URL 蜿悶ｊ霎ｼ縺ｿ縺ｧ縺ｯ favorites 蜿門ｾ励・譛ｪ蟇ｾ蠢懊〒縺吶・
        '逶ｴ謗･繝｡繝・ぅ繧｢ URL 繧貞・蜉帙＠縺ｦ縺上□縺輔＞縲・,
      ); */
      throw const UrlImportDownloaderException(
        'Direct download does not support favorites import',
      );
    }
    if (urls.isEmpty) {
      throw const UrlImportDownloaderException(
        '逶ｴ謗･繝繧ｦ繝ｳ繝ｭ繝ｼ繝峨〒縺阪ｋ URL 縺瑚ｦ九▽縺九ｊ縺ｾ縺帙ｓ縺ｧ縺励◆',
      );
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
            currentFileName: rawUrl, /*
            statusLabel: 'URL 縺九ｉ繝繧ｦ繝ｳ繝ｭ繝ｼ繝峨＠縺ｦ縺・∪縺・,
            */
            statusLabel: 'Downloading URL',
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
        request.headers.set(HttpHeaders.userAgentHeader, _standaloneUserAgent);

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
            currentFileName: fileName, /*
            statusLabel: 'URL 繝繧ｦ繝ｳ繝ｭ繝ｼ繝峨ｒ蜃ｦ逅・＠縺ｦ縺・∪縺・,
            */
            statusLabel: 'Saved URL file',
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

  Future<List<String>> _collectInputUrls(
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

  Future<String?> _resolveSpecialDirectUrl(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return null;
    }

    final host = uri.host.toLowerCase();
    if (host == _dddSmartCdnHost && uri.path.toLowerCase().endsWith('.pdf')) {
      return uri.toString();
    }
    if (host != _dddSmartHost) {
      return null;
    }

    final fileName = uri.pathSegments.isEmpty
        ? ''
        : uri.pathSegments.last.toLowerCase();
    if (fileName == 'show-m.php') {
      return _resolveDddSmartPdfUrlFromShowPage(uri);
    }
    if (fileName.startsWith('dl-')) {
      return _resolveDddSmartPdfUrlFromDownloadPage(uri);
    }

    return null;
  }

  Future<String> _resolveDddSmartPdfUrlFromShowPage(Uri showPageUri) async {
    final html = await _downloadHtml(showPageUri); /*
    final dlHref = _extractAnchorHrefByLabel(html, 'DLページ');
    */
    final dlHref = _extractAnchorHrefByLabel(
      html,
      'DL\u30da\u30fc\u30b8',
    );
    if (dlHref == null) {
      throw UrlImportDownloaderException(
        'ddd-smart DL繝壹・繧ｸ縺後ｦ九▽縺九ｊ縺ｾ縺帙ｓ: $showPageUri',
      );
    }
    return _resolveDddSmartPdfUrlFromDownloadPage(showPageUri.resolve(dlHref));
  }

  Future<String> _resolveDddSmartPdfUrlFromDownloadPage(
    Uri downloadPageUri,
  ) async {
    final html = await _downloadHtml(downloadPageUri);
    /* final pdfHref =
        _extractAnchorHrefByLabel(html, 'PDFダウンロード') ??
        _extractFirstPdfHref(html); */
    final pdfHref =
        _extractAnchorHrefByLabel(
          html,
          'PDF\u30c0\u30a6\u30f3\u30ed\u30fc\u30c9',
        ) ??
        _extractFirstPdfHref(html);
    if (pdfHref == null) {
      throw UrlImportDownloaderException(
        'ddd-smart PDF繝繧ｦ繝ｳ繝ｭ繝ｼ繝峨′隕九▽縺九ｊ縺ｾ縺帙ｓ: $downloadPageUri',
      );
    }
    return downloadPageUri.resolve(pdfHref).toString();
  }

  Future<String> _downloadHtml(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(minutes: 2);
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = true;
      request.headers.set(HttpHeaders.userAgentHeader, _standaloneUserAgent);
      request.headers.set(
        HttpHeaders.acceptHeader,
        'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      );
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        throw UrlImportDownloaderException(
          'HTTP ${response.statusCode} while resolving $uri',
        );
      }
      return await response
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
    } on UrlImportDownloaderException {
      rethrow;
    } on Exception catch (error) {
      throw UrlImportDownloaderException(
        'ddd-smart URL resolving failed: $uri ($error)',
      );
    } finally {
      client.close(force: true);
    }
  }

  String? _extractAnchorHrefByLabel(String html, String label) {
    final anchorPattern = RegExp(
      r"""<a\b[^>]*href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>(.*?)</a>""",
      caseSensitive: false,
      dotAll: true,
    );
    for (final match in anchorPattern.allMatches(html)) {
      final href = (match.group(1) ?? match.group(2) ?? match.group(3) ?? '')
          .trim();
      if (href.isEmpty) {
        continue;
      }
      final anchorText = _normalizeHtmlText(match.group(4) ?? '');
      if (anchorText.contains(label)) {
        return _decodeHtmlEntities(href);
      }
    }
    return null;
  }

  String? _extractFirstPdfHref(String html) {
    final pdfHrefPattern = RegExp(
      r'''href\s*=\s*(?:"([^"]+\.pdf[^"]*)"|'([^']+\.pdf[^']*)'|([^\s>]+\.pdf[^\s>]*))''',
      caseSensitive: false,
      dotAll: true,
    );
    final match = pdfHrefPattern.firstMatch(html);
    final href = (match?.group(1) ?? match?.group(2) ?? match?.group(3) ?? '')
        .trim();
    if (href.isEmpty) {
      return null;
    }
    return _decodeHtmlEntities(href);
  }

  String _normalizeHtmlText(String rawHtml) {
    final withoutTags = rawHtml.replaceAll(RegExp(r'<[^>]+>'), ' ');
    final decoded = _decodeHtmlEntities(withoutTags);
    return decoded.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _decodeHtmlEntities(String input) {
    return input.replaceAllMapped(
      RegExp(r'&(#x?[0-9a-fA-F]+|[a-zA-Z]+);'),
      (match) {
        final token = (match.group(1) ?? '').toLowerCase();
        switch (token) {
          case 'amp':
            return '&';
          case 'lt':
            return '<';
          case 'gt':
            return '>';
          case 'quot':
            return '"';
          case 'apos':
            return "'";
          case 'nbsp':
            return ' ';
        }
        if (token.startsWith('#x')) {
          final value = int.tryParse(token.substring(2), radix: 16);
          return value == null ? match.group(0)! : String.fromCharCode(value);
        }
        if (token.startsWith('#')) {
          final value = int.tryParse(token.substring(1));
          return value == null ? match.group(0)! : String.fromCharCode(value);
        }
        return match.group(0)!;
      },
    );
  }

  bool _supportsLauncherUrl(String rawUrl) {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return false;
    }

    final host = uri.host.toLowerCase();
    if (RegExp(r'^(?:kemono|coomer)\.(?:party|su|cr|st)$').hasMatch(host)) {
      final segments = uri.pathSegments;
      if (segments.length >= 3 &&
          segments[0].isNotEmpty &&
          segments[1].toLowerCase() == 'user' &&
          segments[2].isNotEmpty) {
        return true;
      }
    }

    if (host == 'hitomi.la' && uri.pathSegments.isNotEmpty) {
      return _launcherSupportedHitomiSegments.contains(
        uri.pathSegments.first.toLowerCase(),
      );
    }

    return false;
  }

  UrlImportOptions _copyOptionsWithoutUrlListFile(UrlImportOptions options) {
    return UrlImportOptions(
      cookieMode: options.cookieMode,
      cookieFilePath: options.cookieFilePath,
      favoriteSites: options.favoriteSites,
      favoritePosts: options.favoritePosts,
      favoriteUserServices: options.favoriteUserServices,
      mediaType: options.mediaType,
      parallelDownloads: options.parallelDownloads,
      includeInlineImages: options.includeInlineImages,
      includePostContent: options.includePostContent,
      includeComments: options.includeComments,
      saveJson: options.saveJson,
      overwriteExistingFiles: options.overwriteExistingFiles,
      verbose: options.verbose,
      convertHitomiToPdf: options.convertHitomiToPdf,
    );
  }

  UrlImportOptions _copyOptionsForDirectDownload(UrlImportOptions options) {
    return UrlImportOptions(
      cookieMode: options.cookieMode,
      cookieFilePath: options.cookieFilePath,
      favoriteSites: options.favoriteSites,
      mediaType: options.mediaType,
      parallelDownloads: options.parallelDownloads,
      includeInlineImages: options.includeInlineImages,
      includePostContent: options.includePostContent,
      includeComments: options.includeComments,
      saveJson: options.saveJson,
      overwriteExistingFiles: options.overwriteExistingFiles,
      verbose: options.verbose,
      convertHitomiToPdf: options.convertHitomiToPdf,
    );
  }

  void Function(MediaTransferProgress progress)? _withProgressOffset(
    void Function(MediaTransferProgress progress)? onProgress, {
    required int completedOffset,
    required int trailingFiles,
  }) {
    if (onProgress == null) {
      return null;
    }

    return (progress) {
      final totalFiles = progress.totalFiles > 0
          ? completedOffset + progress.totalFiles + trailingFiles
          : completedOffset + trailingFiles;
      final completedFiles = completedOffset + progress.completedFiles;
      onProgress(
        MediaTransferProgress(
          sentBytes: completedFiles,
          totalBytes: totalFiles,
          completedFiles: completedFiles,
          totalFiles: totalFiles,
          currentFileName: progress.currentFileName,
          statusLabel: progress.statusLabel,
        ),
      );
    };
  }

  int _totalHandledFiles(List<LocalUrlDownloadResult> results) {
    return results.fold<int>(
      0,
      (sum, result) =>
          sum + result.importedCount + result.skippedCount + result.failedCount,
    );
  }

  LocalUrlDownloadResult _mergeDownloadResults(
    List<LocalUrlDownloadResult> results,
  ) {
    if (results.isEmpty) {
      return const LocalUrlDownloadResult(importedCount: 0);
    }
    if (results.length == 1) {
      return results.single;
    }

    final logLines = <String>[];
    final hitomiMetadataByRelativePath = <String, HitomiGalleryMetadata>{};
    var importedCount = 0;
    var skippedCount = 0;
    var failedCount = 0;

    for (final result in results) {
      importedCount += result.importedCount;
      skippedCount += result.skippedCount;
      failedCount += result.failedCount;
      logLines.addAll(result.logLines);
      while (logLines.length > 80) {
        logLines.removeAt(0);
      }
      hitomiMetadataByRelativePath.addAll(result.hitomiMetadataByRelativePath);
    }

    return LocalUrlDownloadResult(
      importedCount: importedCount,
      skippedCount: skippedCount,
      failedCount: failedCount,
      logLines: logLines,
      hitomiMetadataByRelativePath: hitomiMetadataByRelativePath,
    );
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
