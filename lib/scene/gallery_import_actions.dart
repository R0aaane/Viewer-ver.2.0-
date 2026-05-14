// ignore_for_file: file_names, invalid_use_of_protected_member

part of 'gridGallery.dart';

class _RouteBoundDialogHandle {
  BuildContext? _dialogContext;
  bool _closeRequested = false;

  Widget bind(BuildContext context, Widget child) {
    _dialogContext = context;
    if (_closeRequested) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        close();
      });
    }
    return child;
  }

  void close() {
    _closeRequested = true;
    final dialogContext = _dialogContext;
    if (dialogContext == null || !dialogContext.mounted) {
      return;
    }
    final navigator = Navigator.of(dialogContext);
    if (navigator.canPop()) {
      navigator.pop();
    }
    _dialogContext = null;
  }
}

class _PreparedImportSelection {
  final ImportSourceKind sourceKind;
  final List<MediaItem> items;
  final List<String> cleanupPaths;

  const _PreparedImportSelection({
    required this.sourceKind,
    required this.items,
    this.cleanupPaths = const <String>[],
  });
}

class _HostImportFolderGroup {
  final String folderRaw;
  final List<MediaItem> items;

  const _HostImportFolderGroup(this.folderRaw, this.items);
}

extension _GalleryImportActions on _GalleryGridPageState {
  void _bindExternalSharePayloads() {
    _externalShareSubscription = _externalShareService.payloads.listen((
      payload,
    ) {
      unawaited(_queueSharedImportPayload(payload));
    });
    unawaited(() async {
      final payload = await _externalShareService.takeInitialPayload();
      if (payload == null) {
        return;
      }
      await _queueSharedImportPayload(payload);
    }());
  }

  Future<void> _queueSharedImportPayload(ExternalSharePayload payload) async {
    final mediaItems = await _extractSharedImportMediaItems(payload);
    final urls = mediaItems.isEmpty
        ? _extractSharedImportUrls(payload)
        : const <String>[];
    if (mediaItems.isEmpty && urls.isEmpty) {
      return;
    }

    final payloadKey = mediaItems.isNotEmpty
        ? '${payload.action}|${payload.mimeType}|media|${mediaItems.map((item) => item.id).join('\n')}'
        : '${payload.action}|${payload.mimeType}|url|${urls.join('\n')}';
    if (!_handledSharedPayloadKeys.add(payloadKey)) {
      return;
    }

    _pendingSharedImports.add(
      _PendingSharedImport(urls: urls, mediaItems: mediaItems),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(_drainSharedImportQueue());
    });
  }

  Future<List<MediaItem>> _extractSharedImportMediaItems(
    ExternalSharePayload payload,
  ) async {
    try {
      final resolved = await widget.repo.resolveExternalItems(payload.rawItems);
      final mediaItems = <MediaItem>[];
      final seen = <String>{};
      for (final item in resolved) {
        if (item.kind == MediaKind.folder) {
          continue;
        }
        if (seen.add(item.id)) {
          mediaItems.add(item);
        }
      }
      return mediaItems;
    } catch (error, stackTrace) {
      _logUiError('shared-import-resolve', error, stackTrace);
      return const <MediaItem>[];
    }
  }

  List<String> _extractSharedImportUrls(ExternalSharePayload payload) {
    final urls = <String>[];
    final seen = <String>{};
    for (final rawItem in payload.rawItems) {
      for (final url in const UrlImportOptions().collectSourceUrls(rawItem)) {
        if (!_isSupportedSharedImportUrl(url)) {
          continue;
        }
        if (seen.add(url)) {
          urls.add(url);
        }
      }
    }
    return urls;
  }

  bool _isSupportedSharedImportUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null) {
      return false;
    }
    final scheme = uri.scheme.trim().toLowerCase();
    return (scheme == 'http' || scheme == 'https') &&
        uri.host.trim().isNotEmpty;
  }

  Future<void> _drainSharedImportQueue() async {
    if (_processingSharedImport || _initializing || !mounted) {
      return;
    }
    _processingSharedImport = true;
    try {
      while (mounted && !_initializing && _pendingSharedImports.isNotEmpty) {
        final pending = _pendingSharedImports.removeAt(0);
        await _handlePendingSharedImport(pending);
      }
    } finally {
      _processingSharedImport = false;
      if (mounted && !_initializing && _pendingSharedImports.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) {
            return;
          }
          unawaited(_drainSharedImportQueue());
        });
      }
    }
  }

  Future<void> _importToHostWithTags() async {
    if (!_repoCapabilities.canImportToHost) {
      return;
    }

    final result = await ImportToHostDialog.show(
      context,
      tagService: widget.tagService,
      initialSelection: const ImportToHostSelection(
        sourceKind: ImportSourceKind.files,
        items: <MediaItem>[],
      ),
      onPickSelection: _pickHostImportSelectionForDialog,
      supportsHostPdfConversion: true,
    );
    if (result == null) {
      return;
    }
    final selection = result.selection;
    final request = result.request;

    final progress = ValueNotifier<MediaTransferProgress?>(null);
    var dialogShown = false;
    final dialogHandle = _RouteBoundDialogHandle();

    try {
      final lib = await widget.repo.getAppLibraryFolder();
      final libRaw = lib.raw;
      if (!_foldersRaw.contains(libRaw)) {
        setState(() {
          _foldersRaw = <String>[libRaw, ..._foldersRaw];
        });
      }

      if (!mounted) return;

      dialogShown = true;
      unawaited(
        showControllerDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => dialogHandle.bind(
            dialogContext,
            AlertDialog(
              title: const Text('ホストへ取り込み中...'),
              content: ValueListenableBuilder<MediaTransferProgress?>(
                valueListenable: progress,
                builder: (context, value, _) {
                  final fraction = value?.fraction;
                  final completed = value?.completedFiles ?? 0;
                  final total = value?.totalFiles ?? 0;
                  final statusLabel = value?.statusLabel?.trim();
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      LinearProgressIndicator(
                        value: fraction == null || total == 0 ? null : fraction,
                      ),
                      const SizedBox(height: 12),
                      Text(total == 0 ? '準備中...' : '$completed / $total'),
                      if (statusLabel != null && statusLabel.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(statusLabel),
                      ],
                      if (value?.currentFileName != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          value!.currentFileName!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );

      final importedCount = await _runHostImportSelection(
        lib,
        selection,
        request,
        onProgress: (next) => progress.value = next,
      );
      if (!mounted) return;

      if (importedCount <= 0) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('取り込み対象がありませんでした')));
        return;
      }

      String? refreshWarning;
      try {
        _folderItemsCache.clear();
        _folderItemsCacheRecursive.clear();
        _dirStack.clear();

        setState(() {
          _currentFolderRaw = libRaw;
          _folder = lib;
          _page = _MainPage.gallery;
        });
        await _persistFolders();
        await _loadFolder(lib, saveAsLast: false);

        if (!mounted) return;
        await _refreshDetailedBrowseIfNeeded();
        await _refreshCurrentPageTags();
        await _reloadArtistTagMasters();
        await _refreshArtistTagCounts();
      } catch (error, stackTrace) {
        _logUiError('post-import-refresh', error, stackTrace);
        refreshWarning = '一覧の更新に失敗しました: $error';
      }

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ホストへ取り込み完了: $importedCount 件')));
      if (refreshWarning != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(refreshWarning)));
      }
    } catch (e, st) {
      _logUiError('host-import', e, st);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ホスト取り込みに失敗しました: $e')));
    } finally {
      progress.dispose();
      await _cleanupImportSelectionPaths(selection.cleanupPaths);
      if (dialogShown) {
        dialogHandle.close();
      }
    }
  }

  Future<ImportSourceKind?> _pickImportSourceKind() async {
    return showControllerModalBottomSheet<ImportSourceKind>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.upload_file_outlined),
                title: const Text('複数ファイル'),
                subtitle: const Text('PDF や画像を複数選んで取り込みます'),
                onTap: () => Navigator.of(context).pop(ImportSourceKind.files),
              ),
              ListTile(
                leading: const Icon(Icons.folder_open_outlined),
                title: const Text('画像フォルダ'),
                subtitle: const Text('フォルダを選び、中の画像や PDF をまとめて取り込みます'),
                onTap: () => Navigator.of(context).pop(ImportSourceKind.folder),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<_PreparedImportSelection?> _pickHostImportSelection(
    ImportSourceKind sourceKind,
  ) async {
    switch (sourceKind) {
      case ImportSourceKind.files:
        final items = await widget.repo.pickExternalMediaFiles(
          allowMultiple: true,
          includeImages: true,
          includePdf: true,
        );
        if (items.isEmpty) {
          return null;
        }
        return _PreparedImportSelection(sourceKind: sourceKind, items: items);
      case ImportSourceKind.folder:
        final progress = ValueNotifier<MediaTransferProgress?>(
          const MediaTransferProgress(
            sentBytes: 0,
            totalBytes: 0,
            completedFiles: 0,
            totalFiles: 0,
            statusLabel: '取り込み元フォルダを選択しています',
          ),
        );
        var dialogShown = false;
        final dialogHandle = _RouteBoundDialogHandle();
        try {
          void ensureDialogShown() {
            if (dialogShown || !mounted) {
              return;
            }
            dialogShown = true;
            unawaited(
              showControllerDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (dialogContext) => dialogHandle.bind(
                  dialogContext,
                  AlertDialog(
                    title: const Text('取り込み元を確認中...'),
                    content: ValueListenableBuilder<MediaTransferProgress?>(
                      valueListenable: progress,
                      builder: (context, value, _) {
                        final completed = value?.completedFiles ?? 0;
                        final total = value?.totalFiles ?? 0;
                        final statusLabel = value?.statusLabel?.trim();
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const LinearProgressIndicator(),
                            const SizedBox(height: 12),
                            if (total > 0)
                              Text('$completed / $total')
                            else
                              const Text('準備中...'),
                            if (statusLabel != null &&
                                statusLabel.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(statusLabel),
                            ],
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            );
          }

          ensureDialogShown();
          await Future<void>.delayed(Duration.zero);
          final pickedItems = await widget.repo.pickExternalMediaFolderItems(
            onProgress: (processed, total) {
              ensureDialogShown();
              progress.value = MediaTransferProgress(
                sentBytes: 0,
                totalBytes: 0,
                completedFiles: processed,
                totalFiles: total,
                statusLabel: '取り込み元フォルダを走査しています',
              );
            },
          );
          if (pickedItems.isEmpty) {
            return null;
          }
          return _PreparedImportSelection(
            sourceKind: sourceKind,
            items: pickedItems,
          );
        } finally {
          progress.dispose();
          if (dialogShown) {
            dialogHandle.close();
          }
        }
    }
  }

  Future<ImportToHostSelection?> _pickHostImportSelectionForDialog(
    ImportSourceKind sourceKind,
  ) async {
    final selection = await _pickHostImportSelection(sourceKind);
    if (selection == null) {
      return null;
    }
    return ImportToHostSelection(
      sourceKind: selection.sourceKind,
      items: selection.items,
      cleanupPaths: selection.cleanupPaths,
    );
  }

  Future<int> _runHostImportSelection(
    FolderHandle lib,
    ImportToHostSelection selection,
    ImportRequest request, {
    required void Function(MediaTransferProgress progress) onProgress,
  }) async {
    final shouldSplitByFolder =
        request.sourceKind == ImportSourceKind.folder &&
        request.metadata.convertToPdfOnHost;
    if (!shouldSplitByFolder) {
      return widget.repo.importItemsIntoFolder(
        lib,
        selection.items,
        importMetadata: request.metadata,
        skipIfExists: request.skipIfExists,
        onProgress: onProgress,
      );
    }

    final groups = _groupHostImportItemsByFolder(selection.items);
    if (groups.length <= 1) {
      return widget.repo.importItemsIntoFolder(
        lib,
        selection.items,
        importMetadata: request.metadata.copyWith(
          hostPdfFileNameHint: _hostPdfNameHintForFolderGroup(
            selection.items,
            fallback: request.metadata.hostPdfFileNameHint,
          ),
        ),
        skipIfExists: request.skipIfExists,
        onProgress: onProgress,
      );
    }

    var importedCount = 0;
    for (var index = 0; index < groups.length; index++) {
      final group = groups[index];
      final folderName = _hostPdfNameHintForFolderGroup(group.items);
      importedCount += await widget.repo.importItemsIntoFolder(
        lib,
        group.items,
        importMetadata: request.metadata.copyWith(
          hostPdfFileNameHint: folderName,
        ),
        skipIfExists: request.skipIfExists,
        onProgress: (next) {
          onProgress(
            MediaTransferProgress(
              sentBytes: next.sentBytes,
              totalBytes: next.totalBytes,
              completedFiles: next.completedFiles,
              totalFiles: next.totalFiles,
              currentFileName: next.currentFileName,
              statusLabel:
                  '${index + 1} / ${groups.length} フォルダ: ${next.statusLabel ?? folderName}',
            ),
          );
        },
      );
    }
    return importedCount;
  }

  List<_HostImportFolderGroup> _groupHostImportItemsByFolder(
    List<MediaItem> items,
  ) {
    final groups = <String, List<MediaItem>>{};
    for (final item in items) {
      final key = item.folderRaw.trim().isNotEmpty
          ? item.folderRaw.trim()
          : item.id.trim();
      groups.putIfAbsent(key, () => <MediaItem>[]).add(item);
    }
    return groups.entries
        .map((entry) => _HostImportFolderGroup(entry.key, entry.value))
        .toList(growable: false);
  }

  String? _hostPdfNameHintForFolderGroup(
    List<MediaItem> items, {
    String? fallback,
  }) {
    final raw = items.isNotEmpty ? items.first.folderRaw.trim() : '';
    if (raw.isNotEmpty) {
      final normalized = raw.replaceAll('\\', '/');
      final parts = normalized
          .split('/')
          .map((part) => part.trim())
          .where((part) => part.isNotEmpty)
          .toList(growable: false);
      if (parts.isNotEmpty) {
        try {
          return Uri.decodeComponent(parts.last);
        } on ArgumentError {
          return parts.last;
        }
      }
    }
    return fallback;
  }

  Future<void> _cleanupImportSelectionPaths(
    Iterable<String> cleanupPaths,
  ) async {
    for (final path in cleanupPaths) {
      final trimmed = path.trim();
      if (trimmed.isEmpty || trimmed.startsWith('content://')) {
        continue;
      }
      try {
        final file = File(trimmed);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (error) {
        debugPrint(
          '[host-import] temp cleanup failed path=$trimmed error=$error',
        );
      }
    }
  }

  Future<void> _cleanupPreparedImportSelection(
    _PreparedImportSelection selection,
  ) async {
    await _cleanupImportSelectionPaths(selection.cleanupPaths);
  }

  bool get _usesAndroidImportPreparationFlow =>
      Platform.isAndroid && !_repoCapabilities.canImportToHost;

  Future<List<MediaItem>> _pickAndroidFolderImportItems() async {
    final progress = ValueNotifier<MediaTransferProgress?>(
      const MediaTransferProgress(
        sentBytes: 0,
        totalBytes: 0,
        completedFiles: 0,
        totalFiles: 0,
        statusLabel: 'Scanning folder...',
      ),
    );
    var dialogShown = false;
    final dialogHandle = _RouteBoundDialogHandle();
    try {
      void ensureDialogShown() {
        if (dialogShown || !mounted) {
          return;
        }
        dialogShown = true;
        unawaited(
          showControllerDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (dialogContext) => dialogHandle.bind(
              dialogContext,
              AlertDialog(
                title: const Text('Preparing Folder Import...'),
                content: ValueListenableBuilder<MediaTransferProgress?>(
                  valueListenable: progress,
                  builder: (context, value, _) {
                    final completed = value?.completedFiles ?? 0;
                    final total = value?.totalFiles ?? 0;
                    final statusLabel = value?.statusLabel?.trim();
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const LinearProgressIndicator(),
                        const SizedBox(height: 12),
                        Text(total > 0 ? '$completed / $total' : 'Loading...'),
                        if (statusLabel != null && statusLabel.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(statusLabel),
                        ],
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        );
      }

      ensureDialogShown();
      await Future<void>.delayed(Duration.zero);
      final pickedItems = await widget.repo.pickExternalMediaFolderItems(
        onProgress: (processed, total) {
          ensureDialogShown();
          progress.value = MediaTransferProgress(
            sentBytes: 0,
            totalBytes: 0,
            completedFiles: processed,
            totalFiles: total,
            statusLabel: 'Scanning folder...',
          );
        },
      );
      return pickedItems;
    } finally {
      progress.dispose();
      if (dialogShown) {
        dialogHandle.close();
      }
    }
  }

  Future<_AndroidImportConversionChoice?> _pickAndroidImportConversionChoice(
    List<MediaItem> items,
  ) async {
    final imageCount = items
        .where((item) => item.kind == MediaKind.image)
        .length;
    if (imageCount < 2 ||
        !ImportPdfConversionService.canConvertItemsToPdf(items)) {
      return _AndroidImportConversionChoice.keepImages;
    }

    return showControllerModalBottomSheet<_AndroidImportConversionChoice>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('Choose Import Format'),
                subtitle: Text(
                  '$imageCount images were detected. Keep them as images or merge them into one PDF.',
                ),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Import Images'),
                subtitle: Text('Keep $imageCount image files.'),
                onTap: () => Navigator.of(
                  context,
                ).pop(_AndroidImportConversionChoice.keepImages),
              ),
              ListTile(
                leading: const Icon(Icons.picture_as_pdf_outlined),
                title: const Text('Merge into PDF'),
                subtitle: const Text('Create one PDF before importing.'),
                onTap: () => Navigator.of(
                  context,
                ).pop(_AndroidImportConversionChoice.mergeToPdf),
              ),
              ListTile(
                leading: const Icon(Icons.close),
                title: const Text('Cancel'),
                onTap: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<_PreparedImportSelection?> _prepareAndroidImportSelection({
    required ImportSourceKind sourceKind,
    required List<MediaItem> items,
  }) async {
    if (items.isEmpty) {
      return null;
    }

    final choice = await _pickAndroidImportConversionChoice(items);
    if (choice == null) {
      return null;
    }
    if (choice != _AndroidImportConversionChoice.mergeToPdf) {
      return _PreparedImportSelection(sourceKind: sourceKind, items: items);
    }

    String? libraryRootRaw;
    try {
      libraryRootRaw = (await widget.repo.getAppLibraryFolder()).raw;
    } catch (_) {}

    final progress = ValueNotifier<MediaTransferProgress?>(
      const MediaTransferProgress(
        sentBytes: 0,
        totalBytes: 0,
        completedFiles: 0,
        totalFiles: 0,
        statusLabel: 'Building PDF...',
      ),
    );
    var dialogShown = false;
    final dialogHandle = _RouteBoundDialogHandle();
    try {
      if (!mounted) return null;

      dialogShown = true;
      unawaited(
        showControllerDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => dialogHandle.bind(
            dialogContext,
            AlertDialog(
              title: const Text('Building PDF...'),
              content: ValueListenableBuilder<MediaTransferProgress?>(
                valueListenable: progress,
                builder: (context, value, _) {
                  final completed = value?.completedFiles ?? 0;
                  final total = value?.totalFiles ?? 0;
                  final fraction = total == 0 ? null : completed / total;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      LinearProgressIndicator(value: fraction),
                      const SizedBox(height: 12),
                      Text(total > 0 ? '$completed / $total' : 'Loading...'),
                      if (value?.statusLabel != null &&
                          value!.statusLabel!.trim().isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(value.statusLabel!.trim()),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );

      final converted = await ImportPdfConversionService.prepareForImport(
        repo: widget.repo,
        items: items,
        convertToPdf: true,
        libraryRootRaw: libraryRootRaw,
        onPdfProgress: (done, total) {
          progress.value = MediaTransferProgress(
            sentBytes: 0,
            totalBytes: 0,
            completedFiles: done,
            totalFiles: total,
            statusLabel: 'Building PDF...',
          );
        },
      );
      return _PreparedImportSelection(
        sourceKind: sourceKind,
        items: converted.items,
        cleanupPaths: converted.cleanupPaths,
      );
    } finally {
      progress.dispose();
      if (dialogShown) {
        dialogHandle.close();
      }
    }
  }

  Future<_PreparedImportSelection?> _pickAndroidImportSelection() async {
    final sourceKind = await _pickImportSourceKind();
    if (sourceKind == null) {
      return null;
    }

    final items = switch (sourceKind) {
      ImportSourceKind.files => await widget.repo.pickExternalMediaFiles(
        allowMultiple: true,
        includeImages: true,
        includePdf: true,
      ),
      ImportSourceKind.folder => await _pickAndroidFolderImportItems(),
    };
    if (items.isEmpty) {
      return null;
    }

    return _prepareAndroidImportSelection(sourceKind: sourceKind, items: items);
  }

  Future<void> _importToCurrentFolder() async {
    if (_repoCapabilities.canImportToHost) {
      await _importToHostWithTags();
      return;
    }
    if (!_repoCapabilities.canUpload) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('このモードでは取り込みは未対応です')));
      return;
    }
    final folder = _activeImportFolder();
    if (folder == null) return;
    _PreparedImportSelection? selection;
    if (_usesAndroidImportPreparationFlow) {
      selection = await _pickAndroidImportSelection();
      if (selection == null) {
        return;
      }
    }
    final progress = ValueNotifier<MediaTransferProgress?>(null);
    var dialogShown = false;
    final dialogHandle = _RouteBoundDialogHandle();
    try {
      if (!mounted) return;

      dialogShown = true;
      unawaited(
        showControllerDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => dialogHandle.bind(
            dialogContext,
            AlertDialog(
              title: Text(widget.repo.isRemoteMode ? 'アップロード中...' : '取り込み中...'),
              content: ValueListenableBuilder<MediaTransferProgress?>(
                valueListenable: progress,
                builder: (context, value, _) {
                  final fraction = value?.fraction;
                  final completed = value?.completedFiles ?? 0;
                  final total = value?.totalFiles ?? 0;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      LinearProgressIndicator(
                        value: fraction == null || total == 0 ? null : fraction,
                      ),
                      const SizedBox(height: 12),
                      Text(total == 0 ? '準備中...' : '$completed / $total'),
                      if (value?.currentFileName != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          value!.currentFileName!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
      final count = selection == null
          ? await widget.repo.importIntoFolder(
              folder,
              onProgress: (next) => progress.value = next,
            )
          : await widget.repo.importItemsIntoFolder(
              folder,
              selection.items,
              skipIfExists: true,
              onProgress: (next) => progress.value = next,
            );
      if (!mounted) return;

      if (count > 0) {
        try {
          await widget.tagService.requestRescan();
        } catch (_) {}
        await _loadFolder(folder, saveAsLast: false);
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('取り込み完了: $count 件')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('取り込みに失敗しました: $e')));
    } finally {
      progress.dispose();
      if (selection != null) {
        await _cleanupPreparedImportSelection(selection);
      }
      if (dialogShown) {
        dialogHandle.close();
      }
    }
  }

  Future<void> _importToLibraryAndTag() async {
    if (_repoCapabilities.canImportToHost) {
      await _importToHostWithTags();
      return;
    }
    if (!_repoCapabilities.canUpload) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('このモードでは取り込みは未対応です')));
      return;
    }
    final progress = ValueNotifier<MediaTransferProgress?>(null);
    var dialogShown = false;
    final dialogHandle = _RouteBoundDialogHandle();
    _PreparedImportSelection? selection;
    try {
      final lib = await widget.repo.getAppLibraryFolder();
      final libRaw = lib.raw;

      if (!_foldersRaw.contains(libRaw)) {
        setState(() {
          _foldersRaw = <String>[libRaw, ..._foldersRaw];
        });
        await _persistFolders();
      }

      final before = await widget.repo.listMedia(lib);
      final beforeIds = before.map((e) => e.id).toSet();
      if (_usesAndroidImportPreparationFlow) {
        selection = await _pickAndroidImportSelection();
        if (selection == null) {
          return;
        }
      }

      if (!mounted) return;

      dialogShown = true;
      unawaited(
        showControllerDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => dialogHandle.bind(
            dialogContext,
            AlertDialog(
              title: Text(widget.repo.isRemoteMode ? 'アップロード中...' : '取り込み中...'),
              content: ValueListenableBuilder<MediaTransferProgress?>(
                valueListenable: progress,
                builder: (context, value, _) {
                  final fraction = value?.fraction;
                  final completed = value?.completedFiles ?? 0;
                  final total = value?.totalFiles ?? 0;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      LinearProgressIndicator(
                        value: fraction == null || total == 0 ? null : fraction,
                      ),
                      const SizedBox(height: 12),
                      Text(total == 0 ? '準備中...' : '$completed / $total'),
                      if (value?.currentFileName != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          value!.currentFileName!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );

      final importedCount = selection == null
          ? await widget.repo.importIntoFolder(
              lib,
              onProgress: (next) => progress.value = next,
            )
          : await widget.repo.importItemsIntoFolder(
              lib,
              selection.items,
              skipIfExists: true,
              onProgress: (next) => progress.value = next,
            );
      if (!mounted) return;

      if (importedCount <= 0) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('取り込み対象がありませんでした')));
        return;
      }

      try {
        await widget.tagService.requestRescan();
      } catch (_) {}

      final after = await widget.repo.listMedia(lib);
      final newItems = after
          .where((e) => e.kind != MediaKind.folder && !beforeIds.contains(e.id))
          .toList(growable: false);

      _dirStack.clear();
      setState(() {
        _currentFolderRaw = libRaw;
        _page = _MainPage.gallery;
      });
      await _persistFolders();

      await _loadFolder(lib, saveAsLast: false);
      if (!mounted) return;

      if (newItems.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('ライブラリへ取り込み: $importedCount 件（差分なし）')),
        );
        return;
      }

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TagAssignAfterImportPage(
            items: newItems,
            tagService: widget.tagService,
          ),
        ),
      );

      if (!mounted) return;

      await _refreshDetailedBrowseIfNeeded();
      await _refreshCurrentPageTags();
      await _refreshArtistTagCounts();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'ライブラリへ取り込み: $importedCount 件・タグ付け対象: ${newItems.length} 件',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ライブラリ取り込みに失敗しました: $e')));
    } finally {
      progress.dispose();
      if (selection != null) {
        await _cleanupPreparedImportSelection(selection);
      }
      if (dialogShown) {
        dialogHandle.close();
      }
    }
  }

  Future<void> _importUrlToCurrentFolder() async {
    if (!widget.repo.canImportFromUrl) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('このモードでは URL 取り込みは未対応です')));
      return;
    }
    final folder = _activeImportFolder();
    if (folder == null) return;

    await _runUrlImport(
      folder: folder,
      dialogTitle: widget.repo.isRemoteMode
          ? 'URLからホストへ取り込み'
          : 'URLから現在フォルダへ取り込み',
      dialogDescription: widget.repo.isRemoteMode
          ? 'Kemono / Coomer / Hitomi の URL を複数入力するか、お気に入り取得条件を指定して取り込みます。hitomi / kemono や作者階層はタグ化して、メディアは現在フォルダ直下へ整理します。'
          : Platform.isAndroid
          ? '直接メディア URL を複数入力して現在のフォルダへ保存します。Android のスタンドアロン動作では favorites 取得や Cookie 前提のサイト取り込みは未対応です。'
          : 'Kemono / Coomer / Hitomi の URL を複数入力するか、お気に入り取得条件を指定して現在のフォルダ配下へ保存します。',
      progressTitle: 'URL をダウンロードして取り込み中...',
      successLabel: 'URL取り込み',
    );
  }

  Future<void> _handlePendingSharedImport(_PendingSharedImport pending) async {
    if (pending.hasMediaItems) {
      await _handlePendingSharedMediaImport(pending.mediaItems);
      return;
    }
    if (pending.hasUrls) {
      await _handlePendingSharedUrlImport(pending.urls);
    }
  }

  Future<void> _handlePendingSharedMediaImport(
    List<MediaItem> mediaItems,
  ) async {
    if (!_repoCapabilities.canUpload) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('このモードでは共有ファイルの取り込みは未対応です')));
      return;
    }

    final target = await _pickSharedImportTarget(
      title: '共有されたファイルを取り込む',
      subtitle: '${mediaItems.length} 件の PDF / 画像の保存先を選んでください。',
      currentFolderSubtitle: '表示中のフォルダへ取り込みます',
      librarySubtitle: 'ライブラリへ取り込みます',
    );
    if (target == null) {
      return;
    }

    final selection = Platform.isAndroid
        ? await _prepareAndroidImportSelection(
            sourceKind: ImportSourceKind.files,
            items: mediaItems,
          )
        : _PreparedImportSelection(
            sourceKind: ImportSourceKind.files,
            items: mediaItems,
          );
    if (selection == null) {
      return;
    }

    await _runSharedMediaImport(selection: selection, target: target);
  }

  Future<void> _runSharedMediaImport({
    required _PreparedImportSelection selection,
    required _SharedUrlImportTarget target,
  }) async {
    final progress = ValueNotifier<MediaTransferProgress?>(
      MediaTransferProgress(
        sentBytes: 0,
        totalBytes: 0,
        completedFiles: 0,
        totalFiles: selection.items.length,
        statusLabel: '共有ファイルを取り込み中...',
      ),
    );
    var dialogShown = false;
    final dialogHandle = _RouteBoundDialogHandle();
    try {
      dialogShown = true;
      unawaited(
        showControllerDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => dialogHandle.bind(
            dialogContext,
            AlertDialog(
              title: const Text('共有ファイルを取り込み中...'),
              content: ValueListenableBuilder<MediaTransferProgress?>(
                valueListenable: progress,
                builder: (context, value, _) {
                  final fraction = value?.fraction;
                  final completed = value?.completedFiles ?? 0;
                  final total = value?.totalFiles ?? selection.items.length;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      LinearProgressIndicator(
                        value: fraction == null || total == 0 ? null : fraction,
                      ),
                      const SizedBox(height: 12),
                      Text(total == 0 ? '準備中...' : '$completed / $total'),
                      if (value?.currentFileName != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          value!.currentFileName!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );

      final importedCount = await widget.repo.importItemsIntoFolder(
        target.folder,
        selection.items,
        skipIfExists: true,
        onProgress: (next) => progress.value = next,
      );
      if (!mounted) {
        return;
      }

      if (importedCount <= 0) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('取り込み対象がありませんでした')));
        return;
      }

      _folderItemsCache.clear();
      _folderItemsCacheRecursive.clear();
      _dirStack.clear();

      if (target.activateFolder) {
        await _activateImportedFolder(target.folder);
      }

      await _loadFolder(target.folder, saveAsLast: false);
      if (!mounted) {
        return;
      }

      await _refreshDetailedBrowseIfNeeded();
      await _refreshCurrentPageTags();
      await _refreshArtistTagCounts();

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('共有ファイルを取り込みました: $importedCount 件')),
      );
    } catch (error, stackTrace) {
      _logUiError('shared-media-import', error, stackTrace);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('共有ファイルの取り込みに失敗しました: $error')));
    } finally {
      progress.dispose();
      await _cleanupPreparedImportSelection(selection);
      if (dialogShown) {
        dialogHandle.close();
      }
    }
  }

  Future<void> _handlePendingSharedUrlImport(List<String> urls) async {
    if (!widget.repo.canImportFromUrl) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('このモードでは共有 URL の取り込みは未対応です')),
      );
      return;
    }

    final target = await _pickSharedImportTarget(
      title: '共有された URL を取り込む',
      subtitle: '${urls.length} 件の URL の保存先を選んでください。',
      currentFolderSubtitle: '表示中のフォルダへ取り込みます',
      librarySubtitle: 'ライブラリへ取り込みます',
    );
    if (target == null) {
      return;
    }

    await _runUrlImport(
      folder: target.folder,
      dialogTitle: '共有された URL を取り込む',
      dialogDescription:
          '共有された URL を確認して取り込みます。必要に応じて Cookie / favorites を調整してください。',
      progressTitle: '共有 URL を取り込み中...',
      successLabel: '共有 URL を取り込みました',
      activateFolder: target.activateFolder,
      initialSourceText: urls.join('\n'),
    );
  }

  Future<_SharedUrlImportTarget?> _pickSharedImportTarget({
    required String title,
    required String subtitle,
    required String currentFolderSubtitle,
    required String librarySubtitle,
  }) async {
    final libraryFolder = await widget.repo.getAppLibraryFolder();
    if (!mounted) {
      return null;
    }

    final currentFolder = _activeImportFolder();
    final currentFolderRaw = currentFolder?.raw.trim();
    final targets = <_SharedUrlImportTarget>[
      if (currentFolderRaw != null && currentFolderRaw.isNotEmpty)
        _SharedUrlImportTarget(
          kind: _SharedUrlImportTargetKind.currentFolder,
          folder: currentFolder!,
          activateFolder: true,
          folderLabel: _folderLabel(currentFolderRaw),
        ),
      if (currentFolderRaw == null || currentFolderRaw != libraryFolder.raw)
        _SharedUrlImportTarget(
          kind: _SharedUrlImportTargetKind.library,
          folder: libraryFolder,
          activateFolder: true,
          folderLabel: _folderLabel(libraryFolder.raw),
        ),
    ];

    if (targets.isEmpty) {
      return null;
    }
    if (targets.length == 1) {
      return targets.first;
    }

    return showControllerModalBottomSheet<_SharedUrlImportTarget>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(title: Text(title), subtitle: Text(subtitle)),
              for (final target in targets)
                ListTile(
                  leading: Icon(
                    target.kind == _SharedUrlImportTargetKind.currentFolder
                        ? Icons.folder_open_outlined
                        : Icons.library_books_outlined,
                  ),
                  title: Text(target.folderLabel),
                  subtitle: Text(
                    target.kind == _SharedUrlImportTargetKind.currentFolder
                        ? currentFolderSubtitle
                        : librarySubtitle,
                  ),
                  onTap: () => Navigator.of(context).pop(target),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _importUrlToLibrary() async {
    if (!widget.repo.canImportFromUrl) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('このモードでは URL 取り込みは未対応です')));
      return;
    }

    final lib = await widget.repo.getAppLibraryFolder();
    final libRaw = lib.raw;
    if (!_foldersRaw.contains(libRaw)) {
      setState(() {
        _foldersRaw = <String>[libRaw, ..._foldersRaw];
      });
      await _persistFolders();
    }

    await _runUrlImport(
      folder: lib,
      dialogTitle: widget.repo.isRemoteMode
          ? 'URLからホストへ取り込み'
          : 'URLからライブラリへ取り込み',
      dialogDescription: widget.repo.isRemoteMode
          ? 'Kemono / Coomer / Hitomi の URL 複数入力や favorites 取得に対応し、hitomi / kemono や作者階層はタグ化してライブラリ直下へ保存します。'
          : Platform.isAndroid
          ? '直接メディア URL を複数入力してライブラリへ保存します。Android のスタンドアロン動作では favorites 取得や Cookie 前提のサイト取り込みは未対応です。'
          : 'Kemono / Coomer / Hitomi の URL 複数入力や favorites 取得に対応し、creator / post フォルダ構成のままライブラリへ保存します。',
      progressTitle: 'URL をダウンロードして取り込み中...',
      successLabel: 'ライブラリへ URL 取り込み',
      activateFolder: true,
    );
  }

  Future<void> _runUrlImport({
    required FolderHandle folder,
    required String dialogTitle,
    required String dialogDescription,
    required String progressTitle,
    required String successLabel,
    bool activateFolder = false,
    String initialSourceText = '',
  }) async {
    final importRequest = await UrlImportDialog.show(
      context,
      title: dialogTitle,
      description: dialogDescription,
      initialSourceText: initialSourceText,
    );
    if (importRequest == null || !importRequest.hasAnySource) {
      return;
    }

    Set<String>? beforeItemIds;
    try {
      final beforeItems = await widget.repo.listMediaRecursiveFiles(folder);
      beforeItemIds = beforeItems
          .where((item) => item.kind != MediaKind.folder)
          .map((item) => item.id)
          .toSet();
    } catch (error) {
      debugPrint('[url-import] failed to snapshot current items: $error');
    }

    final queueId = _nextUrlImportQueueId();
    _addUrlImportQueueEntry(
      _UrlImportQueueEntry(
        id: queueId,
        title: dialogTitle,
        folderLabel: _folderLabel(folder.raw),
        status: _UrlImportQueueStatus.queued,
        startedAt: DateTime.now(),
        message: progressTitle,
      ),
    );

    try {
      _updateUrlImportQueueEntry(
        queueId,
        (current) => current.copyWith(
          status: _UrlImportQueueStatus.running,
          clearMessage: true,
        ),
      );

      final result = await widget.repo.importFromUrlIntoFolder(
        folder,
        importRequest.sourceUrl,
        options: importRequest.options,
        onProgress: (next) {
          _updateUrlImportQueueEntry(
            queueId,
            (current) => current.copyWith(
              status: _UrlImportQueueStatus.running,
              progress: next,
              message: next.statusLabel,
            ),
          );
        },
      );
      if (!mounted) return;

      final observedImport = await _observeUrlImportChanges(
        folder: folder,
        beforeItemIds: beforeItemIds,
      );
      if (!mounted) return;

      final afterItemsSnapshot = observedImport.afterItemsSnapshot;
      var effectiveImportedCount = result.importedCount;
      if (observedImport.observedImportedCount > effectiveImportedCount) {
        debugPrint(
          '[url-import] corrected imported count from '
          '${result.importedCount} to ${observedImport.observedImportedCount} '
          'folder=${folder.raw}',
        );
        effectiveImportedCount = observedImport.observedImportedCount;
      }

      if (effectiveImportedCount <= 0) {
        final message = result.failedCount > 0
            ? 'URL取り込みに失敗しました（失敗: ${result.failedCount} 件）'
            : result.skippedCount > 0
            ? '新規取り込みはありませんでした（スキップ: ${result.skippedCount} 件）'
            : '取り込み対象がありませんでした';
        _updateUrlImportQueueEntry(
          queueId,
          (current) => current.copyWith(
            status: result.failedCount > 0
                ? _UrlImportQueueStatus.failed
                : _UrlImportQueueStatus.empty,
            clearProgress: true,
            message: message,
            finishedAt: DateTime.now(),
          ),
        );
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
        return;
      }

      var inferredTaggedCount = 0;
      if (!widget.repo.isRemoteMode && beforeItemIds != null) {
        inferredTaggedCount = await _applyInferredTagsToImportedItems(
          folder: folder,
          beforeItemIds: beforeItemIds,
          sourceUrl: importRequest.sourceUrl,
          options: importRequest.options,
          afterItemsSnapshot: afterItemsSnapshot,
          hitomiMetadataByRelativePath: result.hitomiMetadataByRelativePath,
        );
      }
      if (widget.repo.isRemoteMode && result.taggedCount > 0) {
        inferredTaggedCount = result.taggedCount;
      }
      if (widget.repo.isRemoteMode && result.taggedCount > 0) {
        inferredTaggedCount = result.taggedCount;
      }

      _folderItemsCache.clear();
      _folderItemsCacheRecursive.clear();
      _dirStack.clear();

      if (activateFolder) {
        await _activateImportedFolder(folder);
      }

      await _loadFolder(folder, saveAsLast: false);
      if (!mounted) return;

      await _refreshDetailedBrowseIfNeeded();
      await _refreshCurrentPageTags();
      await _refreshArtistTagCounts();

      if (!mounted) return;

      final parts = <String>[
        '$effectiveImportedCount 件',
        if (inferredTaggedCount > 0) 'タグ $inferredTaggedCount 件',
        if (result.skippedCount > 0) 'スキップ ${result.skippedCount} 件',
        if (result.failedCount > 0) '失敗 ${result.failedCount} 件',
      ];
      final organizedSummary = result.organizedCount > 0
          ? ' / 整理 ${result.organizedCount} 件'
          : '';
      final message = '$successLabel: ${parts.join(' / ')}$organizedSummary';
      UrlImportDialog.clearBrowserSession();
      _updateUrlImportQueueEntry(
        queueId,
        (current) => current.copyWith(
          status: _UrlImportQueueStatus.completed,
          clearProgress: true,
          message: message,
          finishedAt: DateTime.now(),
        ),
      );
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      final isTimeoutImportError = _isLikelyTimeoutImportError(e);
      if (isTimeoutImportError) {
        _updateUrlImportQueueEntry(
          queueId,
          (current) => current.copyWith(
            status: _UrlImportQueueStatus.running,
            clearProgress: true,
            message: 'サーバー応答がタイムアウトしました。ホスト側の結果を確認中です...',
          ),
        );
      }
      final observedImport = await _observeUrlImportChanges(
        folder: folder,
        beforeItemIds: beforeItemIds,
        attemptCount: isTimeoutImportError ? 30 : 3,
        retryDelay: isTimeoutImportError
            ? const Duration(seconds: 2)
            : const Duration(milliseconds: 600),
      );
      if (observedImport.observedImportedCount > 0) {
        if (!mounted) return;

        var inferredTaggedCount = 0;
        if (!widget.repo.isRemoteMode && beforeItemIds != null) {
          inferredTaggedCount = await _applyInferredTagsToImportedItems(
            folder: folder,
            beforeItemIds: beforeItemIds,
            sourceUrl: importRequest.sourceUrl,
            options: importRequest.options,
            afterItemsSnapshot: observedImport.afterItemsSnapshot,
          );
        }

        _folderItemsCache.clear();
        _folderItemsCacheRecursive.clear();
        _dirStack.clear();

        if (activateFolder) {
          await _activateImportedFolder(folder);
        }

        await _loadFolder(folder, saveAsLast: false);
        if (!mounted) return;

        await _refreshDetailedBrowseIfNeeded();
        await _refreshCurrentPageTags();
        await _refreshArtistTagCounts();

        if (!mounted) return;

        final recoveryNote = isTimeoutImportError
            ? 'ホスト応答はタイムアウトしましたが、取り込み結果を確認できました'
            : 'エラー後に取り込み結果を確認できました';
        final parts = <String>[
          '${observedImport.observedImportedCount} 件',
          if (inferredTaggedCount > 0) 'タグ $inferredTaggedCount 件',
          recoveryNote,
        ];
        final message = '$successLabel: ${parts.join(' / ')}';
        UrlImportDialog.clearBrowserSession();
        _updateUrlImportQueueEntry(
          queueId,
          (current) => current.copyWith(
            status: isTimeoutImportError
                ? _UrlImportQueueStatus.waiting
                : _UrlImportQueueStatus.completed,
            clearProgress: true,
            message: message,
            finishedAt: DateTime.now(),
          ),
        );
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
        return;
      }

      if (!mounted) return;
      if (isTimeoutImportError) {
        final message =
            'サーバー応答がタイムアウトしました。ホスト側で処理が継続している可能性があります。しばらく待ってから再読み込みして結果を確認してください。';
        _updateUrlImportQueueEntry(
          queueId,
          (current) => current.copyWith(
            status: _UrlImportQueueStatus.waiting,
            clearProgress: true,
            message: message,
            finishedAt: DateTime.now(),
          ),
        );
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
        return;
      }
      final message = 'URL取り込みに失敗しました: $e';
      _updateUrlImportQueueEntry(
        queueId,
        (current) => current.copyWith(
          status: _UrlImportQueueStatus.failed,
          clearProgress: true,
          message: message,
          finishedAt: DateTime.now(),
        ),
      );
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<({List<MediaItem>? afterItemsSnapshot, int observedImportedCount})>
  _observeUrlImportChanges({
    required FolderHandle folder,
    required Set<String>? beforeItemIds,
    int attemptCount = 3,
    Duration retryDelay = const Duration(milliseconds: 600),
  }) async {
    if (beforeItemIds == null) {
      return (afterItemsSnapshot: null, observedImportedCount: 0);
    }
    Object? lastError;
    for (var attempt = 0; attempt < attemptCount; attempt++) {
      try {
        final afterItemsSnapshot = await widget.repo.listMediaRecursiveFiles(
          folder,
        );
        final afterItemIds = afterItemsSnapshot
            .where((item) => item.kind != MediaKind.folder)
            .map((item) => item.id)
            .toSet();
        final observedImportedCount = afterItemIds
            .difference(beforeItemIds)
            .length;
        if (observedImportedCount > 0 || attempt == attemptCount - 1) {
          return (
            afterItemsSnapshot: afterItemsSnapshot,
            observedImportedCount: observedImportedCount,
          );
        }
      } catch (error) {
        lastError = error;
        if (attempt == attemptCount - 1) {
          break;
        }
      }
      await Future<void>.delayed(retryDelay);
    }
    if (lastError != null) {
      debugPrint(
        '[url-import] failed to snapshot imported items after import: '
        '$lastError',
      );
    }
    return (afterItemsSnapshot: null, observedImportedCount: 0);
  }

  bool _isLikelyTimeoutImportError(Object error) {
    if (error is TimeoutException) {
      return true;
    }
    final message = error.toString().toLowerCase();
    return message.contains('timeout') || message.contains('タイムアウト');
  }

  Future<int> _applyInferredTagsToImportedItems({
    required FolderHandle folder,
    required Set<String> beforeItemIds,
    required String sourceUrl,
    required UrlImportOptions options,
    List<MediaItem>? afterItemsSnapshot,
    Map<String, HitomiGalleryMetadata> hitomiMetadataByRelativePath =
        const <String, HitomiGalleryMetadata>{},
  }) async {
    try {
      final afterItems =
          afterItemsSnapshot ??
          await widget.repo.listMediaRecursiveFiles(folder);
      final sourceUrls = options.collectSourceUrls(sourceUrl);
      var taggedCount = 0;

      for (final item in afterItems) {
        if (item.kind == MediaKind.folder || beforeItemIds.contains(item.id)) {
          continue;
        }
        if (item.kind != MediaKind.pdf && item.kind != MediaKind.image) {
          continue;
        }

        try {
          final hitomiMetadata = _lookupHitomiMetadataForImportedItem(
            item,
            folderRaw: folder.raw,
            hitomiMetadataByRelativePath: hitomiMetadataByRelativePath,
          );
          final inferred = ImportTagRuleService.inferForImportedItem(
            itemPath: item.id,
            rootFolderRaw: folder.raw,
            displayName: item.displayName,
            sourceUrls: sourceUrls,
            hitomiMetadata: hitomiMetadata,
          );
          final autoImportTags = _filterUrlImportAutoTagsForItem(
            item.kind,
            inferred.tags,
          );
          if (autoImportTags.isEmpty) {
            continue;
          }

          await widget.tagService.addTagsToItem(item, autoImportTags);
          taggedCount++;
          debugPrint(
            '[url-import] inferred tags for ${item.displayName}: '
            '${autoImportTags.map((tag) => '${tag.category.name}:${tag.name}').join(', ')} '
            '(relative=${inferred.relativePathHint})',
          );
        } catch (error) {
          debugPrint(
            '[url-import] failed to assign inferred tags to ${item.displayName}: $error',
          );
        }
      }

      return taggedCount;
    } catch (error) {
      debugPrint('[url-import] inferred tag assignment failed: $error');
      return 0;
    }
  }

  Future<void> _exportCurrentFolderImagesToPdf() async {
    if (_loading) return;

    final images = _applyFilter(
      _items,
      pdfOnly: false,
    ).where((item) => item.kind == MediaKind.image).toList(growable: false);
    if (images.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('画像がありません')));
      return;
    }

    final folderName = _currentFolderRaw == null
        ? 'export'
        : _folderLabel(_currentFolderRaw!);

    int done = 0;
    final total = images.length;

    showControllerDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('PDF を作成中...'),
        content: StatefulBuilder(
          builder: (context, setD) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: total == 0 ? null : done / total),
              const SizedBox(height: 12),
              Text('$done / $total'),
              const SizedBox(height: 8),
              const Text('保存先フォルダを選択後、処理を開始します。'),
            ],
          ),
        ),
      ),
    );

    try {
      setState(() => _loading = true);

      final created = await PdfExportService.exportFolderToPdfPickLocation(
        widget.repo,
        images,
        folderName,
        onProgress: (d, t) {
          done = d;
          if (mounted) setState(() {});
        },
      );

      if (!mounted) return;
      Navigator.pop(context);

      if (created == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('保存をキャンセルしました')));
      } else {
        final postProcess = await _postProcessGeneratedPdf(
          created: created,
          sourceImages: images,
          sourceFolderLabel: folderName,
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _buildGeneratedPdfResultMessage(
                created: created,
                postProcess: postProcess,
              ),
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('PDF 出力に失敗しました: $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<_GeneratedPdfPostProcessResult> _postProcessGeneratedPdf({
    required PdfExportResult created,
    required List<MediaItem> sourceImages,
    required String sourceFolderLabel,
  }) async {
    final item = await _buildGeneratedPdfItem(created);
    if (item == null) {
      debugPrint(
        '[pdf-export] skipped post-process: generated item not addressable',
      );
      return const _GeneratedPdfPostProcessResult();
    }

    final sourceFolderRaw =
        _currentFolderRaw ??
        (sourceImages.isNotEmpty
            ? sourceImages.first.folderRaw
            : item.folderRaw);

    FolderHandle? libraryFolder;
    try {
      libraryFolder = await widget.repo.getAppLibraryFolder();
    } catch (error) {
      debugPrint('[pdf-export] getAppLibraryFolder failed: $error');
    }

    final inferred = ImportTagRuleService.inferForGeneratedPdf(
      sourceFolderRaw: sourceFolderRaw,
      sourceFolderLabel: sourceFolderLabel,
      generatedFileName: created.savedName,
      libraryRootRaw: libraryFolder?.raw,
    );
    final inheritedTags = await _collectGeneratedPdfInheritedTags(sourceImages);
    final mergedTags = _filterHitomiPdfAutoTags(<Tag>[
      ...inheritedTags,
      ...inferred.tags,
    ]);
    debugPrint(
      '[pdf-export] inferred tags for ${created.savedName}: '
      '${inferred.tags.map((tag) => '${tag.category.name}:${tag.name}').join(', ')} '
      '(relative=${inferred.relativePathHint})',
    );
    debugPrint(
      '[pdf-export] inherited tags for ${created.savedName}: '
      '${inheritedTags.map((tag) => '${tag.category.name}:${tag.name}').join(', ')}',
    );

    String? tagErrorMessage;
    if (mergedTags.isNotEmpty) {
      try {
        await widget.tagService.addTagsToItem(item, mergedTags);
      } catch (error) {
        tagErrorMessage = '$error';
        debugPrint('[pdf-export] tag assignment failed: $error');
      }
    }

    String? organizeErrorMessage;
    String? organizedPath;
    var refreshedCurrentFolder = false;
    if (tagErrorMessage == null &&
        mergedTags.isNotEmpty &&
        libraryFolder != null &&
        _repoCapabilities.canOrganizeLibrary &&
        ImportTagRuleService.isWithinLibrary(
          itemPath: item.id,
          libraryRoot: libraryFolder.raw,
        )) {
      try {
        final moved = await widget.tagService.organizeAppLibrary(
          libraryRoot: libraryFolder.raw,
        );
        organizedPath = moved[item.id];
        if (organizedPath != null) {
          _folderItemsCache.clear();
          _folderItemsCacheRecursive.clear();
          if (_currentFolderRaw != null &&
              _currentFolderRaw!.startsWith(libraryFolder.raw)) {
            refreshedCurrentFolder = true;
            await _loadFolder(
              FolderHandle(_currentFolderRaw!),
              saveAsLast: false,
              pageIndex: _galleryPageIndex,
            );
          }
        }
      } catch (error) {
        organizeErrorMessage = '$error';
        debugPrint('[pdf-export] organize after export failed: $error');
      }
    }

    if (!refreshedCurrentFolder &&
        _currentFolderRaw != null &&
        (created.savedFolderRaw?.trim().isNotEmpty ?? false) &&
        _sameFolderLocation(_currentFolderRaw!, created.savedFolderRaw!)) {
      _folderItemsCache.remove(_currentFolderRaw!);
      _folderItemsCacheRecursive.remove(_currentFolderRaw!);
      await _loadFolder(
        FolderHandle(_currentFolderRaw!),
        saveAsLast: false,
        pageIndex: _galleryPageIndex,
      );
    }

    return _GeneratedPdfPostProcessResult(
      item: item,
      inferredTags: mergedTags,
      relativePathHint: inferred.relativePathHint,
      tagErrorMessage: tagErrorMessage,
      organizeErrorMessage: organizeErrorMessage,
      organizedPath: organizedPath,
    );
  }

  Future<List<Tag>> _collectGeneratedPdfInheritedTags(
    List<MediaItem> sourceImages,
  ) async {
    final imageSources = sourceImages
        .where((item) => item.kind == MediaKind.image)
        .toList(growable: false);
    if (imageSources.isEmpty) {
      return const <Tag>[];
    }

    final knownDetails = <String, List<TagWithId>>{};
    for (final item in imageSources) {
      final cached = _tagDetailsById[item.id];
      if (cached != null) {
        knownDetails[item.id] = cached;
      }
    }

    Map<String, List<TagWithId>> details = knownDetails;
    if (details.length != imageSources.length) {
      try {
        details = await widget.tagService.getDetailedTagsByItems(imageSources);
      } catch (error) {
        debugPrint('[pdf-export] source tag lookup failed: $error');
      }
    }

    final out = <Tag>[];
    final seen = <String>{};
    for (final item in imageSources) {
      for (final entry in details[item.id] ?? const <TagWithId>[]) {
        final tag = entry.tag;
        final isArtist = tag.category == TagCategory.artist;
        final isImportSourceMediaType =
            tag.category == TagCategory.mediaType &&
            _isImportPdfAutoTagMediaType(tag.name);
        if (!isArtist && !isImportSourceMediaType) {
          continue;
        }
        final key = '${tag.category.name}\u0000${tag.name.toLowerCase()}';
        if (!seen.add(key)) {
          continue;
        }
        out.add(Tag(name: tag.name, category: tag.category));
      }
    }
    return out;
  }

  List<Tag> _filterUrlImportAutoTagsForItem(
    MediaKind kind,
    Iterable<Tag> tags,
  ) {
    if (kind == MediaKind.pdf || kind == MediaKind.image) {
      return _filterHitomiPdfAutoTags(tags);
    }

    final out = <Tag>[];
    final seen = <String>{};
    for (final tag in tags) {
      final normalizedName = tag.name.trim();
      if (normalizedName.isEmpty) {
        continue;
      }
      final isSupportedMediaType =
          tag.category == TagCategory.mediaType &&
          _isImportPdfAutoTagMediaType(normalizedName);
      if (!isSupportedMediaType) {
        continue;
      }

      final key = '${tag.category.name}\u0000${normalizedName.toLowerCase()}';
      if (!seen.add(key)) {
        continue;
      }
      out.add(Tag(name: normalizedName, category: tag.category));
    }
    return out;
  }

  List<Tag> _filterHitomiPdfAutoTags(Iterable<Tag> tags) {
    final out = <Tag>[];
    final seen = <String>{};
    var hasSupportedMediaType = false;

    for (final tag in tags) {
      final normalizedName = tag.name.trim();
      if (normalizedName.isEmpty) {
        continue;
      }

      final isArtist = tag.category == TagCategory.artist;
      final isSeries = tag.category == TagCategory.series;
      final isCharacter = tag.category == TagCategory.character;
      final isFree = tag.category == TagCategory.free;
      final isSupportedMediaType =
          tag.category == TagCategory.mediaType &&
          _isImportPdfAutoTagMediaType(normalizedName);
      if (!isArtist &&
          !isSeries &&
          !isCharacter &&
          !isFree &&
          !isSupportedMediaType) {
        continue;
      }

      if (isSupportedMediaType) {
        hasSupportedMediaType = true;
      }

      final key = '${tag.category.name}\u0000${normalizedName.toLowerCase()}';
      if (!seen.add(key)) {
        continue;
      }
      out.add(Tag(name: normalizedName, category: tag.category));
    }

    if (!hasSupportedMediaType) {
      return const <Tag>[];
    }
    return out;
  }

  bool _isImportPdfAutoTagMediaType(String name) {
    final normalized = name.trim().toLowerCase();
    return normalized == 'hitomi' || normalized == 'ddd-smart';
  }

  Future<MediaItem?> _buildGeneratedPdfItem(PdfExportResult created) async {
    if ((created.savedPath?.trim().isNotEmpty ?? false)) {
      final path = created.savedPath!.trim();
      try {
        final file = File(path);
        final stat = await file.stat();
        return MediaItem(
          id: file.path,
          displayName: created.savedName,
          kind: MediaKind.pdf,
          folderRaw: created.savedFolderRaw ?? file.parent.path,
          modified: stat.modified,
          sizeBytes: stat.size,
          tags: const <Tag>[],
        );
      } catch (error) {
        debugPrint('[pdf-export] failed to stat generated file: $error');
      }
    }

    if ((created.savedUri?.trim().isNotEmpty ?? false)) {
      return MediaItem(
        id: created.savedUri!.trim(),
        displayName: created.savedName,
        kind: MediaKind.pdf,
        folderRaw: (created.savedFolderRaw ?? created.savedUri!).trim(),
        modified: DateTime.now(),
        tags: const <Tag>[],
      );
    }

    return null;
  }

  String _buildGeneratedPdfResultMessage({
    required PdfExportResult created,
    required _GeneratedPdfPostProcessResult postProcess,
  }) {
    final parts = <String>['PDF を保存しました: ${created.name}'];
    if (postProcess.inferredTags.isNotEmpty) {
      parts.add('タグ ${postProcess.inferredTags.length} 件を付与');
    }
    if (postProcess.organized) {
      parts.add('既存整理で階層反映');
    }
    if (postProcess.hasTagFailure) {
      parts.add('タグ付与失敗: ${postProcess.tagErrorMessage}');
    }
    if (postProcess.hasOrganizeFailure) {
      parts.add('整理失敗: ${postProcess.organizeErrorMessage}');
    }
    return parts.join(' / ');
  }

  String _nextUrlImportQueueId() =>
      'url-import-${DateTime.now().microsecondsSinceEpoch}';

  void _addUrlImportQueueEntry(_UrlImportQueueEntry entry) {
    setState(() {
      _urlImportQueue.insert(0, entry);
      while (_urlImportQueue.length > 8) {
        _urlImportQueue.removeLast();
      }
      _showUrlImportQueue = true;
    });
  }

  void _updateUrlImportQueueEntry(
    String id,
    _UrlImportQueueEntry Function(_UrlImportQueueEntry current) update,
  ) {
    if (!mounted) return;
    setState(() {
      final index = _urlImportQueue.indexWhere((entry) => entry.id == id);
      if (index < 0) return;
      _urlImportQueue[index] = update(_urlImportQueue[index]);
    });
  }

  void _removeUrlImportQueueEntry(String id) {
    if (!mounted) return;
    setState(() {
      _urlImportQueue.removeWhere((entry) => entry.id == id);
    });
  }

  String _queueStatusLabel(_UrlImportQueueEntry entry) {
    switch (entry.status) {
      case _UrlImportQueueStatus.queued:
        return '待機中';
      case _UrlImportQueueStatus.running:
        return entry.progress?.statusLabel ?? 'ダウンロード中';
      case _UrlImportQueueStatus.waiting:
        return '確認待ち';
      case _UrlImportQueueStatus.completed:
        return '完了';
      case _UrlImportQueueStatus.empty:
        return '差分なし';
      case _UrlImportQueueStatus.failed:
        return '失敗';
    }
  }

  Color _queueStatusColor(BuildContext context, _UrlImportQueueEntry entry) {
    switch (entry.status) {
      case _UrlImportQueueStatus.waiting:
        return Colors.orange.shade400;
      case _UrlImportQueueStatus.completed:
        return Colors.green.shade400;
      case _UrlImportQueueStatus.empty:
        return Theme.of(context).colorScheme.primary;
      case _UrlImportQueueStatus.failed:
        return Theme.of(context).colorScheme.error;
      case _UrlImportQueueStatus.queued:
      case _UrlImportQueueStatus.running:
        return Theme.of(context).colorScheme.outline;
    }
  }

  Widget _buildUrlImportQueueOverlay() {
    if (_urlImportQueue.isEmpty) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    return Positioned(
      right: 16,
      bottom: 16,
      child: SafeArea(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360, maxHeight: 420),
          child: Card(
            elevation: 6,
            child: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.download_outlined),
                    title: Text('ダウンロードキュー (${_urlImportQueue.length})'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: _showUrlImportQueue ? '折りたたむ' : '展開',
                          onPressed: () {
                            setState(
                              () => _showUrlImportQueue = !_showUrlImportQueue,
                            );
                          },
                          icon: Icon(
                            _showUrlImportQueue
                                ? Icons.expand_more
                                : Icons.chevron_left,
                          ),
                        ),
                        IconButton(
                          tooltip: '完了済みを閉じる',
                          onPressed: () {
                            setState(() {
                              _urlImportQueue.removeWhere(
                                (entry) =>
                                    entry.status !=
                                        _UrlImportQueueStatus.running &&
                                    entry.status !=
                                        _UrlImportQueueStatus.queued,
                              );
                            });
                          },
                          icon: const Icon(Icons.clear_all),
                        ),
                      ],
                    ),
                  ),
                  if (_showUrlImportQueue)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 320),
                      child: ListView.separated(
                        shrinkWrap: true,
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        itemCount: _urlImportQueue.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final entry = _urlImportQueue[index];
                          final progress = entry.progress;
                          final total = progress?.totalFiles ?? 0;
                          final completed = progress?.completedFiles ?? 0;
                          final showLinear =
                              entry.status == _UrlImportQueueStatus.running;
                          final linearValue = total > 0
                              ? progress?.fraction
                              : null;

                          return Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: _queueStatusColor(context, entry),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            entry.title,
                                            style: theme.textTheme.titleSmall,
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            entry.folderLabel,
                                            style: theme.textTheme.bodySmall,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    IconButton(
                                      tooltip: '閉じる',
                                      onPressed: () =>
                                          _removeUrlImportQueueEntry(entry.id),
                                      icon: const Icon(Icons.close, size: 18),
                                    ),
                                  ],
                                ),
                                Text(
                                  _queueStatusLabel(entry),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: _queueStatusColor(context, entry),
                                  ),
                                ),
                                if (showLinear) ...[
                                  const SizedBox(height: 8),
                                  LinearProgressIndicator(value: linearValue),
                                  const SizedBox(height: 6),
                                  Text(
                                    total == 0
                                        ? '準備中...'
                                        : '$completed / $total',
                                  ),
                                ],
                                if (progress?.currentFileName != null) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    progress!.currentFileName!,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                                if (entry.message != null) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    entry.message!,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _wrapBodyWithUrlImportQueue(Widget body) {
    return Stack(
      fit: StackFit.expand,
      children: [body, _buildUrlImportQueueOverlay()],
    );
  }

  Future<void> _importSelectedToLibrary(List<MediaItem> targets) async {
    final mediaTargets = targets
        .where((item) => item.kind != MediaKind.folder)
        .toList(growable: false);
    if (mediaTargets.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('取り込み対象がありません')));
      return;
    }
    if (!_repoCapabilities.canUpload) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('このモードでは取り込みは未対応です')));
      return;
    }

    final lib = await widget.repo.getAppLibraryFolder();

    final before = await widget.repo.listMedia(lib);
    final beforeIds = before.map((e) => e.id).toSet();

    final imported = await widget.repo.importItemsIntoFolder(
      lib,
      mediaTargets,
      skipIfExists: true,
    );

    if (imported <= 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('取り込み対象がありません（既に取り込み済みの可能性）')),
      );
      return;
    }

    final after = await widget.repo.listMedia(lib);
    final newItems = after
        .where((e) => e.kind != MediaKind.folder && !beforeIds.contains(e.id))
        .toList(growable: false);

    if (!mounted) return;

    if (newItems.isNotEmpty) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TagAssignAfterImportPage(
            items: newItems,
            tagService: widget.tagService,
          ),
        ),
      );
    }

    _exitSelectMode();
    setState(() {});
  }
}
