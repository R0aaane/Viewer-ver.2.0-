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
  final Map<String, HitomiGalleryMetadata> metadataByDirectUrl;

  const _PreparedUrlImportSources({
    this.launcherUrls = const <String>[],
    this.directUrls = const <String>[],
    this.metadataByDirectUrl = const <String, HitomiGalleryMetadata>{},
  });

  bool get hasLauncherUrls => launcherUrls.isNotEmpty;
  bool get hasDirectUrls => directUrls.isNotEmpty;
  bool get isEmpty => launcherUrls.isEmpty && directUrls.isEmpty;
}

class _ResolvedDirectUrl {
  final String url;
  final HitomiGalleryMetadata? metadata;

  const _ResolvedDirectUrl({required this.url, this.metadata});
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
    final directMetadataByUrl = <String, HitomiGalleryMetadata>{
      ...prepared.metadataByDirectUrl,
    };
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
        metadataByUrl: directMetadataByUrl,
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
    final metadataByDirectUrl = <String, HitomiGalleryMetadata>{};
    final launcherSeen = <String>{};
    final directSeen = <String>{};

    for (final rawUrl in await _collectInputUrls(sourceUrl, options)) {
      final resolvedDirectUrl = await _resolveSpecialDirectUrl(rawUrl);
      if (resolvedDirectUrl != null) {
        if (directSeen.add(resolvedDirectUrl.url)) {
          directUrls.add(resolvedDirectUrl.url);
        }
        if (resolvedDirectUrl.metadata != null) {
          metadataByDirectUrl[resolvedDirectUrl.url] =
              resolvedDirectUrl.metadata!;
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
      metadataByDirectUrl: metadataByDirectUrl,
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
    final hitomiMetadataByRelativePath = <String, HitomiGalleryMetadata>{};
    var sawEvent = false;

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
    final metadataByUrl = <String, HitomiGalleryMetadata>{
      ...prepared.metadataByDirectUrl,
    };
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
    final hitomiMetadataByRelativePath = <String, HitomiGalleryMetadata>{};

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
            /*
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
        final importMetadata = metadataByUrl[rawUrl];
        try {
          fileName = _buildDownloadFileName(
            uri,
            response,
            sequence: importedCount + skippedCount + failedCount + 1,
            metadata: importMetadata,
          );
        } on UrlImportDownloaderException catch (error) {
          failedCount++;
          appendLog('[error] ${error.message}: $rawUrl');
          await response.drain<void>();
          continue;
        }

        final targetPath = p.join(destinationDir.path, fileName);
        final targetFile = File(targetPath);
        final relativeKey = HitomiGalleryMetadata.normalizeRelativePathKey(
          fileName,
        );
        if (relativeKey != null && importMetadata != null) {
          hitomiMetadataByRelativePath[relativeKey] = importMetadata;
        }
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
            /*
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
      hitomiMetadataByRelativePath: hitomiMetadataByRelativePath,
    );
  }

  Future<LocalUrlDownloadResult> _runDirectUrlDownloadUrls({
    required List<String> urls,
    required String destinationFolder,
    required UrlImportOptions options,
    Map<String, HitomiGalleryMetadata> metadataByUrl =
        const <String, HitomiGalleryMetadata>{},
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
    final hitomiMetadataByRelativePath = <String, HitomiGalleryMetadata>{};

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
            /*
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
        final importMetadata = metadataByUrl[rawUrl];
        try {
          fileName = _buildDownloadFileName(
            uri,
            response,
            sequence: importedCount + skippedCount + failedCount + 1,
            metadata: importMetadata,
          );
        } on UrlImportDownloaderException catch (error) {
          failedCount++;
          appendLog('[error] ${error.message}: $rawUrl');
          await response.drain<void>();
          continue;
        }

        final targetPath = p.join(destinationDir.path, fileName);
        final targetFile = File(targetPath);
        final relativeKey = HitomiGalleryMetadata.normalizeRelativePathKey(
          fileName,
        );
        if (relativeKey != null && importMetadata != null) {
          hitomiMetadataByRelativePath[relativeKey] = importMetadata;
        }
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
            /*
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
      hitomiMetadataByRelativePath: hitomiMetadataByRelativePath,
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

  Future<_ResolvedDirectUrl?> _resolveSpecialDirectUrl(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return null;
    }

    final host = uri.host.toLowerCase();
    if (host == _dddSmartCdnHost && uri.path.toLowerCase().endsWith('.pdf')) {
      return _ResolvedDirectUrl(url: uri.toString());
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
      final resolvedUrl = await _resolveDddSmartPdfUrlFromDownloadPage(uri);
      return _ResolvedDirectUrl(url: resolvedUrl);
    }

    return null;
  }

  Future<_ResolvedDirectUrl> _resolveDddSmartPdfUrlFromShowPage(
    Uri showPageUri,
  ) async {
    final html = await _downloadHtml(showPageUri);
    final dlHref =
        _extractAnchorHrefByLabel(html, 'DL\u30da\u30fc\u30b8') ??
        _extractFirstDddSmartDownloadPageHref(html);
    if (dlHref == null) {
      throw UrlImportDownloaderException(
        'ddd-smart DL page link was not found: $showPageUri',
      );
    }
    final resolvedUrl = await _resolveDddSmartPdfUrlFromDownloadPage(
      showPageUri.resolve(dlHref),
    );
    return _ResolvedDirectUrl(
      url: resolvedUrl,
      metadata: _extractDddSmartMetadataFromShowPage(html, showPageUri),
    );
  }

  Future<String> _resolveDddSmartPdfUrlFromDownloadPage(
    Uri downloadPageUri,
  ) async {
    final html = await _downloadHtml(downloadPageUri);
    final pdfHref =
        _extractAnchorHrefByLabel(
          html,
          'PDF\u30c0\u30a6\u30f3\u30ed\u30fc\u30c9',
        ) ??
        _extractFirstPdfHref(html);
    if (pdfHref == null) {
      throw UrlImportDownloaderException(
        'ddd-smart PDF link was not found: $downloadPageUri',
      );
    }
    return downloadPageUri.resolve(pdfHref).toString();
  }

  HitomiGalleryMetadata _extractDddSmartMetadataFromShowPage(
    String html,
    Uri showPageUri,
  ) {
    final scopedHtml = _extractDddSmartMetadataScope(html);
    final title = _extractDddSmartTitle(scopedHtml);
    final circles = _extractDddSmartKeywordsFromSection(
      scopedHtml,
      sectionLabels: const <String>['\u30b5\u30fc\u30af\u30eb'],
      expectedType: '3',
    );
    return HitomiGalleryMetadata(
      artists: circles,
      groups: circles,
      series: _extractDddSmartKeywordsFromSection(
        scopedHtml,
        sectionLabels: const <String>['\u539f\u4f5c'],
        expectedType: '1',
      ),
      characters: _extractDddSmartKeywordsFromSection(
        scopedHtml,
        sectionLabels: const <String>['\u30ad\u30e3\u30e9\u30af\u30bf\u30fc'],
        expectedType: '2',
      ),
      tags: _extractDddSmartKeywordsFromSection(
        scopedHtml,
        sectionLabels: const <String>['\u30bf\u30b0'],
        expectedType: '4',
      ),
      title: title,
      japaneseTitle: title,
      mediaType: 'ddd-smart',
      sourceUrl: showPageUri.toString(),
      readerUrl: showPageUri.toString(),
    );
  }

  String _extractDddSmartMetadataScope(String html) {
    const markers = <String>[
      'DL\u30da\u30fc\u30b8',
      '\u4e00\u89a7\u8aad\u307f',
      'PDF\u30c0\u30a6\u30f3\u30ed\u30fc\u30c9',
    ];
    for (final marker in markers) {
      final index = html.indexOf(marker);
      if (index < 0) {
        continue;
      }
      final start = index > 20000 ? index - 20000 : 0;
      final end = index + 20000 < html.length ? index + 20000 : html.length;
      return html.substring(start, end);
    }
    return html;
  }

  String? _extractDddSmartTitle(String html) {
    final patterns = <RegExp>[
      RegExp(r'<h1\b[^>]*>(.*?)</h1>', caseSensitive: false, dotAll: true),
      RegExp(
        r'''<h2\b[^>]*class\s*=\s*(?:"[^"]*\bcard-panel\b[^"]*"|'[^']*\bcard-panel\b[^']*')[^>]*>(.*?)</h2>''',
        caseSensitive: false,
        dotAll: true,
      ),
      RegExp(
        r'''<div\b[^>]*class\s*=\s*(?:"[^"]*\bcard-panel\b[^"]*"|'[^']*\bcard-panel\b[^']*')[^>]*>(.*?)</div>''',
        caseSensitive: false,
        dotAll: true,
      ),
      RegExp(r'<title>(.*?)</title>', caseSensitive: false, dotAll: true),
    ];
    for (final pattern in patterns) {
      for (final match in pattern.allMatches(html)) {
        final text = _normalizeHtmlText(match.group(1) ?? '');
        if (_looksLikeDddSmartTitle(text)) {
          return text;
        }
      }
    }
    return null;
  }

  bool _looksLikeDddSmartTitle(String text) {
    final normalized = text.trim();
    if (normalized.isEmpty || normalized.length < 4) {
      return false;
    }

    const blockedExact = <String>{
      '\u539f\u4f5c',
      '\u30ad\u30e3\u30e9',
      '\u30ad\u30e3\u30e9\u30af\u30bf\u30fc',
      '\u30b5\u30fc\u30af\u30eb',
      '\u30bf\u30b0',
      '\u66f4\u65b0\u65e5',
      '\u767a\u884c\u65e5',
      '\u30aa\u30b9\u30b9\u30e1\u5ea6',
      '\u4e00\u89a7\u8aad\u307f',
      'DL\u30da\u30fc\u30b8',
      'PDF\u30c0\u30a6\u30f3\u30ed\u30fc\u30c9',
    };
    if (blockedExact.contains(normalized)) {
      return false;
    }

    return !normalized.contains('\u540c\u4eba\u3059\u307e\u30fc\u3068') &&
        !normalized.contains('ddd-smart') &&
        !normalized.contains('\u304b\u3089\u63a2\u3059') &&
        !normalized.contains('\u4e00\u89a7') &&
        !normalized.contains('\u30e9\u30f3\u30ad\u30f3\u30b0');
  }

  List<String> _extractDddSmartKeywordsFromSection(
    String html, {
    required List<String> sectionLabels,
    required String expectedType,
  }) {
    final sectionHtml = _extractDddSmartSectionHtml(
      html,
      sectionLabels: sectionLabels,
    );
    if (sectionHtml == null) {
      return const <String>[];
    }
    return _extractDddSmartKeywordsByType(
      sectionHtml,
      expectedType: expectedType,
    );
  }

  String? _extractDddSmartSectionHtml(
    String html, {
    required List<String> sectionLabels,
  }) {
    var start = -1;
    for (final label in sectionLabels) {
      final index = html.indexOf(label);
      if (index >= 0 && (start < 0 || index < start)) {
        start = index;
      }
    }
    if (start < 0) {
      return null;
    }

    const boundaryLabels = <String>[
      '\u539f\u4f5c',
      '\u30ad\u30e3\u30e9',
      '\u30ad\u30e3\u30e9\u30af\u30bf\u30fc',
      '\u30b5\u30fc\u30af\u30eb',
      '\u30bf\u30b0',
      '\u66f4\u65b0\u65e5',
      '\u767a\u884c\u65e5',
      '\u30aa\u30b9\u30b9\u30e1\u5ea6',
      '\u4e00\u89a7\u8aad\u307f',
      'DL\u30da\u30fc\u30b8',
    ];
    var end = html.length;
    for (final label in boundaryLabels) {
      if (sectionLabels.contains(label)) {
        continue;
      }
      final index = html.indexOf(label, start + 1);
      if (index >= 0 && index < end) {
        end = index;
      }
    }

    final maxEnd = start + 4000;
    if (end > maxEnd) {
      end = maxEnd < html.length ? maxEnd : html.length;
    }
    if (end <= start) {
      return null;
    }
    return html.substring(start, end);
  }

  List<String> _extractDddSmartKeywordsByType(
    String html, {
    required String expectedType,
  }) {
    final out = <String>[];
    final seen = <String>{};
    final anchorPattern = RegExp(
      r"""<a\b[^>]*href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>(.*?)</a>""",
      caseSensitive: false,
      dotAll: true,
    );
    for (final match in anchorPattern.allMatches(html)) {
      final href = _decodeHtmlEntities(
        (match.group(1) ?? match.group(2) ?? match.group(3) ?? '').trim(),
      );
      final keyword = _extractDddSmartKeywordFromHref(
        href,
        expectedType: expectedType,
      );
      if (keyword == null) {
        continue;
      }
      final lowered = keyword.toLowerCase();
      if (seen.add(lowered)) {
        out.add(keyword);
      }
    }
    return out;
  }

  String? _extractDddSmartKeywordFromHref(
    String href, {
    required String expectedType,
  }) {
    if (href.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(href);
    if (uri == null || uri.path.isEmpty) {
      return null;
    }
    final type = uri.queryParameters['type']?.trim();
    final keyword = uri.queryParameters['keyword']?.trim();
    if (type != expectedType || keyword == null || keyword.isEmpty) {
      return null;
    }
    return keyword;
  }

  String? _extractFirstDddSmartDownloadPageHref(String html) {
    final dlHrefPattern = RegExp(
      r'''href\s*=\s*(?:"([^"]*\/dl-[^"]+)"|'([^']*\/dl-[^']+)'|([^\s>]*\/dl-[^\s>]+))''',
      caseSensitive: false,
      dotAll: true,
    );
    final match = dlHrefPattern.firstMatch(html);
    final href = (match?.group(1) ?? match?.group(2) ?? match?.group(3) ?? '')
        .trim();
    if (href.isEmpty) {
      return null;
    }
    return _decodeHtmlEntities(href);
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
    return input.replaceAllMapped(RegExp(r'&(#x?[0-9a-fA-F]+|[a-zA-Z]+);'), (
      match,
    ) {
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
    });
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
    HitomiGalleryMetadata? metadata,
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
    final preferredExtension = MediaFileTypes.extensionOf(
      fileName ?? preferred,
    );
    final titleFallbackExtension = preferredExtension.isNotEmpty
        ? preferredExtension
        : inferredExtension;
    if (_shouldReplaceGenericDownloadFileName(fileName)) {
      fileName =
          _buildTitleBasedFileName(
            metadata,
            preferredExtension: titleFallbackExtension,
          ) ??
          fileName;
    }
    fileName ??=
        _buildTitleBasedFileName(
          metadata,
          preferredExtension: inferredExtension,
        ) ??
        'download_$sequence${inferredExtension ?? ''}';

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

  bool _shouldReplaceGenericDownloadFileName(String? fileName) {
    if (fileName == null) {
      return false;
    }
    final baseName = p.basenameWithoutExtension(fileName).trim().toLowerCase();
    return baseName == 'all';
  }

  String? _buildTitleBasedFileName(
    HitomiGalleryMetadata? metadata, {
    String? preferredExtension,
  }) {
    if (metadata == null) {
      return null;
    }
    final title =
        _trimmedOrNull(metadata.japaneseTitle) ??
        _trimmedOrNull(metadata.title) ??
        _trimmedOrNull(metadata.englishTitle);
    final sanitizedTitle = _sanitizeFileName(title ?? '');
    if (sanitizedTitle == null) {
      return null;
    }
    if (MediaFileTypes.extensionOf(sanitizedTitle).isNotEmpty) {
      return sanitizedTitle;
    }
    final extension = (preferredExtension ?? '').trim();
    if (extension.isEmpty) {
      return sanitizedTitle;
    }
    return '$sanitizedTitle$extension';
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
