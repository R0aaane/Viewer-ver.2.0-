// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/mediaItem.dart';
import '../models/metadata_settings.dart';
import '../models/tag.dart';
import '../repository/mediaRepository.dart';
import '../services/app_settings_service.dart';
import '../services/item_name_service.dart';
import 'web_remote_api_client.dart';

enum _WebMediaFilter {
  pdf('PDF');

  final String label;
  const _WebMediaFilter(this.label);
}

enum _WebRemoteSurface {
  home,
  browse,
}

enum _WebBrowserDisplayMode {
  list(
    label: 'リスト',
    compactLabel: '一覧',
    icon: Icons.view_agenda_outlined,
  ),
  tile(
    label: 'タイル',
    compactLabel: '1枚',
    icon: Icons.crop_portrait_rounded,
  ),
  threeUp(
    label: '3列',
    compactLabel: '3列',
    icon: Icons.grid_view_rounded,
  );

  final String label;
  final String compactLabel;
  final IconData icon;

  const _WebBrowserDisplayMode({
    required this.label,
    required this.compactLabel,
    required this.icon,
  });
}

class WebRemoteViewerPage extends StatefulWidget {
  final MetadataSettings initialSettings;
  final AppSettingsService settingsService;

  const WebRemoteViewerPage({
    super.key,
    required this.initialSettings,
    required this.settingsService,
  });

  @override
  State<WebRemoteViewerPage> createState() => _WebRemoteViewerPageState();
}

class _WebRemoteViewerPageState extends State<WebRemoteViewerPage> {
  static const String _browserDisplayModePrefsKey =
      'prefs.webRemoteBrowserDisplayMode';

  late MetadataSettings _settings;
  late final TextEditingController _apiController;
  late final TextEditingController _tokenController;
  late final TextEditingController _searchController;

  WebRemoteApiClient? _client;
  List<WebRemoteFolder> _folders = const <WebRemoteFolder>[];
  List<WebRemoteEntry> _entries = const <WebRemoteEntry>[];
  List<WebRemoteEntry> _homeEntries = const <WebRemoteEntry>[];
  WebRemoteEntry? _selectedEntry;
  WebRemoteFolder? _libraryRoot;
  String? _selectedFolderRaw;
  bool _isConnecting = false;
  bool _isLoading = false;
  bool _homeLoading = false;
  bool _actionBusy = false;
  String? _statusMessage;
  String? _errorMessage;
  String? _homeErrorMessage;
  _WebMediaFilter _filter = _WebMediaFilter.pdf;
  _WebRemoteSurface _surface = _WebRemoteSurface.home;
  _WebBrowserDisplayMode _browserDisplayMode = _WebBrowserDisplayMode.list;

  @override
  void initState() {
    super.initState();
    _settings = _resolveInitialSettings(widget.initialSettings);
    _apiController = TextEditingController(text: _settings.clientApiBaseUrl);
    _tokenController = TextEditingController(text: _settings.authToken ?? '');
    _searchController = TextEditingController();
    unawaited(_restoreBrowserDisplayMode());
    if (_settings.clientApiBaseUrl.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _saveAndConnect(showSuccessMessage: false);
      });
    }
  }

  @override
  void dispose() {
    _apiController.dispose();
    _tokenController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  MetadataSettings _resolveInitialSettings(MetadataSettings settings) {
    final apiFromUri = Uri.base.queryParameters['api']?.trim();
    final tokenFromUri = Uri.base.queryParameters['token']?.trim();
    final fallbackApiBaseUrl = _resolveInitialApiBaseUrl(
      settings,
      apiFromUri: apiFromUri,
    );
    return settings.copyWith(
      appMode: AppMode.client,
      clientApiBaseUrl: apiFromUri ?? fallbackApiBaseUrl,
      authToken: tokenFromUri ?? settings.authToken,
      clearAuthToken: tokenFromUri != null && tokenFromUri.isEmpty,
    );
  }

  Future<void> _restoreBrowserDisplayMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_browserDisplayModePrefsKey)?.trim();
      final normalizedRaw = raw == 'tiles' ? 'tile' : raw;
      final restored =
          _WebBrowserDisplayMode.values
              .where((mode) => mode.name == normalizedRaw)
              .cast<_WebBrowserDisplayMode?>()
              .firstOrNull ??
          _WebBrowserDisplayMode.list;
      if (!mounted) {
        return;
      }
      setState(() {
        _browserDisplayMode = restored;
      });
    } catch (error) {
      debugPrint(
        '[WebRemoteViewerPage] Failed to restore browser display mode: $error',
      );
    }
  }

  Future<void> _persistBrowserDisplayMode(_WebBrowserDisplayMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_browserDisplayModePrefsKey, mode.name);
    } catch (error) {
      debugPrint(
        '[WebRemoteViewerPage] Failed to persist browser display mode: $error',
      );
    }
  }

  void _setBrowserDisplayMode(_WebBrowserDisplayMode mode) {
    if (_browserDisplayMode == mode) {
      return;
    }
    setState(() {
      _browserDisplayMode = mode;
    });
    unawaited(_persistBrowserDisplayMode(mode));
  }

  String _resolveInitialApiBaseUrl(
    MetadataSettings settings, {
    required String? apiFromUri,
  }) {
    final apiFromQuery = apiFromUri?.trim();
    if (apiFromQuery != null && apiFromQuery.isNotEmpty) {
      return apiFromQuery;
    }

    final storedApi = settings.clientApiBaseUrl.trim();
    if (storedApi.isNotEmpty) {
      return storedApi;
    }

    final inferredApi = _inferApiBaseUrlFromCurrentLocation(settings.hostPort);
    if (inferredApi != null && inferredApi.isNotEmpty) {
      return inferredApi;
    }

    if (settings.isHostMode) {
      return settings.hostLoopbackApiBaseUrl;
    }

    return '';
  }

  String? _inferApiBaseUrlFromCurrentLocation(int port) {
    final currentUri = Uri.base;
    final host = currentUri.host.trim();
    if (host.isEmpty) {
      return null;
    }

    final normalizedHost = _isLoopbackHost(host) ? '127.0.0.1' : host;
    // Host API is served over plain HTTP today.
    return Uri(scheme: 'http', host: normalizedHost, port: port).toString();
  }

  bool _isLoopbackHost(String host) {
    final lowered = host.trim().toLowerCase();
    return lowered == 'localhost' ||
        lowered == '127.0.0.1' ||
        lowered == '::1' ||
        lowered == '[::1]';
  }

  String? _browserCompatibilityError(String apiBaseUrl) {
    final currentHost = Uri.base.host.trim();
    final currentScheme = Uri.base.scheme.trim().toLowerCase();
    final apiUri = Uri.tryParse(apiBaseUrl.trim());
    if (apiUri == null || !apiUri.hasScheme || apiUri.host.trim().isEmpty) {
      return null;
    }

    final apiScheme = apiUri.scheme.trim().toLowerCase();
    final apiHost = apiUri.host.trim();

    if (!_isLoopbackHost(currentHost) && _isLoopbackHost(apiHost)) {
      return 'この端末からは 127.0.0.1 / localhost の API に接続できません。PC の LAN IP またはホスト名を指定してください。';
    }

    if (currentScheme == 'https' && apiScheme == 'http') {
      return 'HTTPS の Web ページから HTTP API には接続できません。Safari では特にブロックされやすいため、Web ビューアーも HTTP で開くか、API 側を HTTPS で公開してください。';
    }

    return null;
  }

  Future<void> _saveAndConnect({bool showSuccessMessage = true}) async {
    final apiBaseUrl = _apiController.text.trim();
    final authToken = _tokenController.text.trim();
    final nextSettings = _settings.copyWith(
      appMode: AppMode.client,
      clientApiBaseUrl: apiBaseUrl,
      authToken: authToken,
      clearAuthToken: authToken.isEmpty,
    );

    setState(() {
      _settings = nextSettings;
      _errorMessage = null;
      _statusMessage = null;
      _isConnecting = true;
    });
    await widget.settingsService.saveMetadataSettings(nextSettings);

    if (apiBaseUrl.isEmpty) {
      if (!mounted) return;
      setState(() {
        _client = null;
        _folders = const <WebRemoteFolder>[];
        _entries = const <WebRemoteEntry>[];
        _homeEntries = const <WebRemoteEntry>[];
        _libraryRoot = null;
        _selectedEntry = null;
        _selectedFolderRaw = null;
        _isConnecting = false;
        _homeErrorMessage = null;
        _statusMessage = 'API URL を入力すると Web から閲覧できます';
      });
      return;
    }

    final compatibilityError = _browserCompatibilityError(apiBaseUrl);
    if (compatibilityError != null) {
      if (!mounted) return;
      setState(() {
        _client = null;
        _folders = const <WebRemoteFolder>[];
        _entries = const <WebRemoteEntry>[];
        _homeEntries = const <WebRemoteEntry>[];
        _libraryRoot = null;
        _selectedEntry = null;
        _selectedFolderRaw = null;
        _isConnecting = false;
        _errorMessage = compatibilityError;
        _homeErrorMessage = compatibilityError;
      });
      return;
    }

    final client = WebRemoteApiClient(
      baseUrl: apiBaseUrl,
      authToken: authToken.isEmpty ? null : authToken,
    );

    try {
      final folders = await client.listFolders();
      final libraryRoot = _resolveLibraryRoot(folders);
      final selectedFolder = libraryRoot?.raw;
      if (!mounted) return;
      setState(() {
        _client = client;
        _folders =
            libraryRoot == null
                ? const <WebRemoteFolder>[]
                : <WebRemoteFolder>[libraryRoot];
        _libraryRoot = libraryRoot;
        _selectedFolderRaw = selectedFolder;
        _surface = _WebRemoteSurface.home;
        _statusMessage = '接続済み: ${_settings.clientApiBaseUrl}';
      });
      if (selectedFolder != null) {
        await _refreshHomeEntries(force: true);
        await _loadEntries();
      }
      if (!mounted || !showSuccessMessage) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Web 閲覧に接続しました: ${_settings.clientApiBaseUrl}')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _client = null;
        _folders = const <WebRemoteFolder>[];
        _entries = const <WebRemoteEntry>[];
        _homeEntries = const <WebRemoteEntry>[];
        _libraryRoot = null;
        _selectedEntry = null;
        _errorMessage = error.toString();
        _homeErrorMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isConnecting = false;
        });
      }
    }
  }

  Future<void> _loadEntries({bool reuseHomeOnEmptyQuery = true}) async {
    final client = _client;
    final folderRaw = _selectedFolderRaw;
    if (client == null || folderRaw == null || folderRaw.trim().isEmpty) {
      setState(() {
        _entries = const <WebRemoteEntry>[];
        _selectedEntry = null;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final rawQuery = _searchController.text.trim();
      final fetched =
          rawQuery.isEmpty && reuseHomeOnEmptyQuery && _homeEntries.isNotEmpty
              ? _sortedPdfEntries(_homeEntries)
              : _sortedPdfEntries(
                await _loadPdfEntries(
                  client,
                  folderRaw: folderRaw,
                  rawQuery: rawQuery,
                ),
              );
      final filtered = _applyFilter(fetched);
      WebRemoteEntry? nextSelected = _selectedEntry;
      if (nextSelected != null) {
        final stableId = nextSelected.stableId;
        nextSelected = filtered
            .where((entry) => entry.stableId == stableId)
            .cast<WebRemoteEntry?>()
            .firstOrNull;
      }
      nextSelected ??= filtered.cast<WebRemoteEntry?>().firstOrNull;
      if (!mounted) return;
      setState(() {
        _entries = filtered;
        _selectedEntry = nextSelected;
        if (rawQuery.isEmpty) {
          _homeEntries = filtered;
          _homeErrorMessage = null;
        }
        _statusMessage =
            rawQuery.isEmpty
                ? 'PDF 一覧: ${filtered.length}件'
                : 'PDF 検索: ${filtered.length}件';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _entries = const <WebRemoteEntry>[];
        _selectedEntry = null;
        _errorMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  List<WebRemoteEntry> _sortedPdfEntries(Iterable<WebRemoteEntry> entries) {
    final sorted = entries.toList(growable: false);
    sorted.sort((left, right) {
      final leftModified = left.modifiedAt?.millisecondsSinceEpoch ?? 0;
      final rightModified = right.modifiedAt?.millisecondsSinceEpoch ?? 0;
      final modifiedCompare = rightModified.compareTo(leftModified);
      if (modifiedCompare != 0) {
        return modifiedCompare;
      }
      return left.displayName.toLowerCase().compareTo(right.displayName.toLowerCase());
    });
    return sorted;
  }

  Future<void> _refreshHomeEntries({bool force = false}) async {
    final client = _client;
    final folderRaw = _libraryRoot?.raw ?? _selectedFolderRaw;
    if (client == null || folderRaw == null || folderRaw.trim().isEmpty) {
      if (!mounted) {
        return;
      }
      setState(() {
        _homeEntries = const <WebRemoteEntry>[];
        _homeErrorMessage = null;
      });
      return;
    }
    if (!force && _homeEntries.isNotEmpty) {
      return;
    }

    if (mounted) {
      setState(() {
        _homeLoading = true;
        _homeErrorMessage = null;
      });
    }

    try {
      final fetched = await _loadPdfEntries(
        client,
        folderRaw: folderRaw,
        rawQuery: '',
      );
      final sorted = _sortedPdfEntries(fetched);
      if (!mounted) {
        return;
      }
      setState(() {
        _homeEntries = sorted;
        _homeErrorMessage = null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _homeEntries = const <WebRemoteEntry>[];
        _homeErrorMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _homeLoading = false;
        });
      }
    }
  }

  Future<void> _recordEntryView(WebRemoteEntry entry) async {
    final client = _client;
    final mediaId = entry.mediaId?.trim();
    if (!entry.isPdf || client == null || mediaId == null || mediaId.isEmpty) {
      return;
    }
    try {
      final stats = await client.recordMediaView(mediaId);
      if (!mounted) {
        return;
      }
      setState(() {
        _entries = _replaceEntryStats(_entries, entry.stableId, stats);
        _homeEntries = _replaceEntryStats(_homeEntries, entry.stableId, stats);
        if (_selectedEntry?.stableId == entry.stableId) {
          _selectedEntry = _selectedEntry?.copyWith(stats: stats);
        }
      });
    } catch (error, stackTrace) {
      debugPrint('[WebRemoteViewerPage] Failed to record media view: $error');
      debugPrintStack(
        label: '[WebRemoteViewerPage] _recordEntryView',
        stackTrace: stackTrace,
      );
    }
  }

  List<WebRemoteEntry> _replaceEntryStats(
    List<WebRemoteEntry> entries,
    String stableId,
    WebRemoteMediaStats stats,
  ) {
    if (entries.isEmpty) {
      return entries;
    }
    return entries
        .map(
          (candidate) =>
              candidate.stableId == stableId
                  ? candidate.copyWith(stats: stats)
                  : candidate,
        )
        .toList(growable: false);
  }

  Future<List<WebRemoteEntry>> _loadPdfEntries(
    WebRemoteApiClient client, {
    required String folderRaw,
    required String rawQuery,
  }) async {
    final query = _buildPdfOnlySearchQuery(rawQuery);
    const pageSize = 1000;
    final entries = <WebRemoteEntry>[];
    var offset = 0;

    while (true) {
      final page = await client.search(
        query,
        folderRaw: folderRaw,
        limit: pageSize,
        offset: offset,
      );
      if (page.isEmpty) {
        break;
      }
      entries.addAll(page.where((entry) => entry.isPdf));
      if (page.length < pageSize) {
        break;
      }
      offset += page.length;
    }

    return entries;
  }

  WebSearchQuery _buildPdfOnlySearchQuery(String rawQuery) {
    final parsed = WebSearchParser.parse(rawQuery);
    return WebSearchQuery(
      raw: parsed.raw,
      q: parsed.q,
      artist: parsed.artist,
      series: parsed.series,
      character: parsed.character,
      mediaType: 'pdf',
      name: parsed.name,
      untagged: parsed.untagged,
    );
  }

  List<WebRemoteEntry> _applyFilter(List<WebRemoteEntry> items) {
    return items.where((entry) => entry.isPdf).toList();
  }

  p.Context _pathContext(String raw) {
    return raw.contains('\\')
        ? p.Context(style: p.Style.windows)
        : p.Context(style: p.Style.posix);
  }

  String _folderName(String raw) {
    final context = _pathContext(raw);
    final name = context.basename(raw);
    return name.isEmpty ? raw : name;
  }

  int _browserGridColumnCount(double width) {
    return 3;
  }

  String? _parentFolder(String raw) {
    final context = _pathContext(raw);
    final parent = context.dirname(raw);
    if (parent == '.' || parent == raw) {
      return null;
    }
    return parent;
  }

  WebRemoteFolder? _resolveLibraryRoot(List<WebRemoteFolder> folders) {
    if (folders.isEmpty) {
      return null;
    }

    int scoreFolder(WebRemoteFolder folder) {
      final raw = folder.raw.trim();
      final displayName = folder.displayName.trim().toLowerCase();
      final baseName = _folderName(raw).trim().toLowerCase();
      var score = 0;
      if (displayName == 'library' || baseName == 'library') {
        score += 100;
      }
      if (displayName.contains('library') ||
          baseName.contains('library') ||
          raw.toLowerCase().contains('library')) {
        score += 30;
      }
      score -= raw.length ~/ 12;
      return score;
    }

    var best = folders.first;
    var bestScore = scoreFolder(best);
    for (final folder in folders.skip(1)) {
      final currentScore = scoreFolder(folder);
      if (currentScore > bestScore) {
        best = folder;
        bestScore = currentScore;
      }
    }
    return best;
  }

  String _normalizePathForContext(String raw, p.Context context) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    final normalized = context.normalize(trimmed);
    final rootPrefix = context.rootPrefix(normalized);
    var value = normalized;
    while (value.length > rootPrefix.length &&
        (value.endsWith('\\') || value.endsWith('/'))) {
      value = value.substring(0, value.length - 1);
    }
    final ignoreCase =
        trimmed.contains('\\') || RegExp(r'^[A-Za-z]:').hasMatch(trimmed);
    return ignoreCase ? value.toLowerCase() : value;
  }

  bool _isPathWithin(String raw, String rootRaw) {
    final context = _pathContext(rootRaw);
    final normalizedRaw = _normalizePathForContext(raw, context);
    final normalizedRoot = _normalizePathForContext(rootRaw, context);
    if (normalizedRaw.isEmpty || normalizedRoot.isEmpty) {
      return false;
    }
    if (normalizedRaw == normalizedRoot) {
      return true;
    }
    final separator =
        rootRaw.contains('\\') || RegExp(r'^[A-Za-z]:').hasMatch(rootRaw)
            ? '\\'
            : '/';
    return normalizedRaw.startsWith('$normalizedRoot$separator');
  }

  bool _isSamePath(String left, String right) {
    final context = _pathContext(left.trim().isNotEmpty ? left : right);
    return _normalizePathForContext(left, context) ==
        _normalizePathForContext(right, context);
  }

  String? _parentFolderWithinLibrary(String raw) {
    final parent = _parentFolder(raw);
    final libraryRootRaw = _libraryRoot?.raw;
    if (parent == null) {
      return null;
    }
    if (libraryRootRaw == null) {
      return parent;
    }
    return _isPathWithin(parent, libraryRootRaw) ? parent : null;
  }

  String _currentFolderLabel(String? folderRaw) {
    final libraryRoot = _libraryRoot;
    final trimmed = folderRaw?.trim();
    if (libraryRoot == null) {
      return trimmed == null || trimmed.isEmpty ? 'Library' : _folderName(trimmed);
    }
    if (trimmed == null || trimmed.isEmpty || _isSamePath(trimmed, libraryRoot.raw)) {
      return libraryRoot.displayName.trim().isEmpty
          ? _folderName(libraryRoot.raw)
          : libraryRoot.displayName.trim();
    }
    final context = _pathContext(libraryRoot.raw);
    final relative = context.relative(
      context.normalize(trimmed),
      from: context.normalize(libraryRoot.raw),
    );
    final parts = relative
        .split(RegExp(r'[\\/]'))
        .where((part) => part.trim().isNotEmpty)
        .toList(growable: false);
    final rootLabel =
        libraryRoot.displayName.trim().isEmpty
            ? _folderName(libraryRoot.raw)
            : libraryRoot.displayName.trim();
    if (parts.isEmpty) {
      return rootLabel;
    }
    return '$rootLabel / ${parts.join(' / ')}';
  }

  Future<void> _selectFolder(String folderRaw) async {
    final libraryRootRaw = _libraryRoot?.raw;
    if (libraryRootRaw != null && !_isPathWithin(folderRaw, libraryRootRaw)) {
      return;
    }
    setState(() {
      _surface = _WebRemoteSurface.browse;
      _selectedFolderRaw = folderRaw;
      _selectedEntry = null;
    });
    await _loadEntries();
  }

  Future<void> _openDetailPage(
    WebRemoteEntry entry, {
    bool allowOpenPdfViewer = true,
  }) async {
    final client = _client;
    if (!mounted || client == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder:
            (pageContext) => Scaffold(
              appBar: AppBar(title: Text(_entryDisplayTitle(entry))),
              body: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: WebMediaDetailView(
                    client: client,
                    entry: entry,
                    onApplyTagQuery: (query) async {
                      _searchController.text = query;
                      await _loadEntries();
                      if (pageContext.mounted) {
                        Navigator.of(pageContext).pop();
                      }
                    },
                    onOpenPdfViewerPage:
                        allowOpenPdfViewer && entry.isPdf
                            ? () => _openPdfViewerPage(entry)
                            : null,
                  ),
                ),
              ),
            ),
      ),
    );
  }

  Future<void> _openPdfViewerPage(WebRemoteEntry entry) async {
    final client = _client;
    if (!mounted || client == null || !entry.isPdf) return;
    await _recordEntryView(entry);
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder:
            (_) => WebPdfViewerPage(
              client: client,
              entry: entry,
              onOpenDetail:
                  () => _openDetailPage(entry, allowOpenPdfViewer: false),
            ),
      ),
    );
  }

  Future<void> _handleEntryTap(WebRemoteEntry entry, {required bool splitView}) async {
    if (entry.isFolder) {
      await _selectFolder(entry.fullPath ?? entry.entryId);
      return;
    }
    setState(() {
      _selectedEntry = entry;
    });
    if (splitView) {
      return;
    }
    await _openDetailPage(entry);
  }

  Future<void> _applyTagQuery(String query) async {
    _searchController.text = query;
    setState(() {
      _surface = _WebRemoteSurface.browse;
    });
    await _loadEntries();
  }

  Future<T?> _runRemoteAction<T>({
    required String workingStatus,
    required Future<T> Function(WebRemoteApiClient client) action,
  }) async {
    final client = _client;
    if (client == null || _actionBusy) {
      return null;
    }

    setState(() {
      _actionBusy = true;
      _errorMessage = null;
      _statusMessage = workingStatus;
    });

    try {
      return await action(client);
    } catch (error) {
      if (!mounted) {
        return null;
      }
      setState(() {
        _errorMessage = error.toString();
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
      return null;
    } finally {
      if (mounted) {
        setState(() {
          _actionBusy = false;
        });
      }
    }
  }

  Future<void> _importUrlToCurrentFolder() async {
    final folderRaw = _selectedFolderRaw?.trim();
    if (folderRaw == null || folderRaw.isEmpty) {
      return;
    }

    final request = await _WebUrlImportDialog.show(
      context,
      folderName: _folderName(folderRaw),
    );
    if (request == null || !request.hasAnySource) {
      return;
    }

    final result = await _runRemoteAction<WebRemoteUrlImportResult>(
      workingStatus: 'URL 取り込みを実行中...',
      action: (client) {
        return client.downloadUrl(
          folderRaw: folderRaw,
          sourceUrl: request.sourceUrl,
          options: request.options,
          importMetadata: request.importMetadata,
        );
      },
    );
    if (result == null || !mounted) {
      return;
    }

    await _refreshHomeEntries(force: true);
    await _loadEntries();
    if (!mounted) {
      return;
    }

    final message =
        'URL 取り込み完了: 追加 ${result.importedCount} 件 / '
        '整理 ${result.organizedCount} 件 / '
        'スキップ ${result.skippedCount} 件 / '
        '失敗 ${result.failedCount} 件';
    setState(() {
      _statusMessage = message;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _organizeCurrentFolder() async {
    final folderRaw = _selectedFolderRaw?.trim();
    if (folderRaw == null || folderRaw.isEmpty) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('現在フォルダを整理'),
          content: Text(
            'ホストに整理を依頼します。\n\n$folderRaw',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('整理する'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }

    final result = await _runRemoteAction<WebRemoteOrganizeResult>(
      workingStatus: 'フォルダ整理を実行中...',
      action: (client) => client.organizeLibrary(folderRaw),
    );
    if (result == null || !mounted) {
      return;
    }

    await _refreshHomeEntries(force: true);
    await _loadEntries();
    if (!mounted) {
      return;
    }

    final message =
        '整理完了: 移動 ${result.movedCount} 件 / '
        '再スキャン ${result.rescannedCount} 件';
    setState(() {
      _statusMessage = message;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _requestRescanCurrentFolder() async {
    final folderRaw = _selectedFolderRaw?.trim();

    final completed = await _runRemoteAction<bool>(
      workingStatus: folderRaw == null || folderRaw.isEmpty
          ? 'ホスト全体を再スキャン中...'
          : '現在フォルダを再スキャン中...',
      action: (client) async {
        await client.requestRescan(folderRaw: folderRaw);
        return true;
      },
    );
    if (completed != true || !mounted) {
      return;
    }

    await _refreshHomeEntries(force: true);
    await _loadEntries();
    if (!mounted) {
      return;
    }

    final message = folderRaw == null || folderRaw.isEmpty
        ? '再スキャンを完了しました'
        : '現在フォルダの再スキャンを完了しました';
    setState(() {
      _statusMessage = message;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final showSidebar = constraints.maxWidth >= 980;
        final splitView = constraints.maxWidth >= 1180;
        final compactScreen = constraints.maxWidth < 720;
        final keyboardVisible = MediaQuery.of(context).viewInsets.bottom > 0;
        final contentPadding = EdgeInsets.fromLTRB(
          compactScreen ? 10 : 16,
          compactScreen ? 10 : 16,
          compactScreen ? 10 : 16,
          keyboardVisible ? 10 : 16,
        );
        final mainContent =
            _surface == _WebRemoteSurface.home
                ? _buildHomePane()
                : splitView
                ? Row(
                  children: <Widget>[
                    Expanded(flex: 6, child: _buildBrowserPane(splitView)),
                    const SizedBox(width: 16),
                    SizedBox(width: 420, child: _buildDetailPane()),
                  ],
                )
                : _buildBrowserPane(splitView);

        return Scaffold(
          resizeToAvoidBottomInset: true,
          appBar: AppBar(
            title: const Text('Web メディアビューア'),
            leading:
                showSidebar
                    ? null
                    : Builder(
                      builder:
                          (context) => IconButton(
                            icon: const Icon(Icons.menu),
                            onPressed: () => Scaffold.of(context).openDrawer(),
                          ),
                    ),
            actions: <Widget>[
              if (_isConnecting || _isLoading || _actionBusy)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
            ],
          ),
          drawer: showSidebar ? null : Drawer(child: _buildSidebar()),
          body: SafeArea(
            child: Row(
              children: <Widget>[
                if (showSidebar) SizedBox(width: 320, child: _buildSidebar()),
                if (showSidebar) const VerticalDivider(width: 1),
                Expanded(
                  child: Padding(
                    padding: contentPadding,
                    child: mainContent,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSidebar() {
    return Container(
      color: const Color(0xFF101114),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          const Text('Web 接続', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          TextField(
            controller: _apiController,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'API URL',
              hintText: 'http://192.168.1.10:8000',
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _tokenController,
            decoration: const InputDecoration(
              labelText: 'Bearer Token',
              hintText: 'change-this-token',
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _isConnecting ? null : _saveAndConnect,
            icon: const Icon(Icons.link),
            label: const Text('保存して接続'),
          ),
          const SizedBox(height: 12),
          _buildInfoCard(
            '接続状態',
            _errorMessage ??
                _statusMessage ??
                'API URL とトークンを設定すると、iPhone などのブラウザから閲覧できます',
            _errorMessage == null ? Colors.white70 : Colors.red.shade200,
          ),
          const SizedBox(height: 16),
          const Text('フォルダ', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          const Text('Navigation', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: <Widget>[
                ListTile(
                  selected: _surface == _WebRemoteSurface.home,
                  selectedTileColor: const Color(0xFF1B2D47),
                  leading: const Icon(Icons.home_outlined),
                  title: const Text('ホーム'),
                  subtitle: const Text('新着 / 未読 / よく見る作品'),
                  onTap: () {
                    setState(() {
                      _surface = _WebRemoteSurface.home;
                    });
                  },
                ),
                ListTile(
                  selected: _surface == _WebRemoteSurface.browse,
                  selectedTileColor: const Color(0xFF1B2D47),
                  leading: const Icon(Icons.picture_as_pdf_outlined),
                  title: const Text('PDF一覧'),
                  subtitle: const Text('PDF を検索して詳細を確認'),
                  onTap: () {
                    setState(() {
                      _surface = _WebRemoteSurface.browse;
                    });
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Text('Library', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          if (_folders.isEmpty)
            const Text('接続後に閲覧可能なフォルダを表示します。', style: TextStyle(color: Colors.white60)),
          for (final folder in _folders)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                selected:
                    _selectedFolderRaw != null &&
                    _isPathWithin(_selectedFolderRaw!, folder.raw),
                selectedTileColor: const Color(0xFF1B2D47),
                leading: const Icon(Icons.folder_outlined),
                title: Text(folder.displayName),
                subtitle:
                    folder.lastScannedAt == null
                        ? Text(folder.raw, maxLines: 1, overflow: TextOverflow.ellipsis)
                        : Text('最終更新 ${_formatDateTime(folder.lastScannedAt)}'),
                onTap: () => _selectFolder(folder.raw),
              ),
            ),
          const SizedBox(height: 16),
          _buildUnsupportedFeaturesCard(),
        ],
      ),
    );
  }

  DateTime _addedAtForEntry(WebRemoteEntry entry) {
    return (entry.stats?.addedAt ?? entry.modifiedAt ?? DateTime.now()).toLocal();
  }

  int _viewCountForEntry(WebRemoteEntry entry) {
    return entry.stats?.viewCount ?? 0;
  }

  DateTime? _lastViewedAtForEntry(WebRemoteEntry entry) {
    return entry.stats?.lastViewedAt?.toLocal();
  }

  List<_WebHomeSectionData> _buildHomeSections(List<WebRemoteEntry> entries) {
    final recentlyAdded = entries.toList(growable: false)
      ..sort((left, right) => _addedAtForEntry(right).compareTo(_addedAtForEntry(left)));
    final viewed = entries.where((entry) => _viewCountForEntry(entry) > 0).toList(growable: false);
    final frequentlyViewed = viewed.toList(growable: false)
      ..sort((left, right) {
        final countCompare = _viewCountForEntry(right).compareTo(_viewCountForEntry(left));
        if (countCompare != 0) {
          return countCompare;
        }
        final rightViewed = _lastViewedAtForEntry(right) ?? DateTime.fromMillisecondsSinceEpoch(0);
        final leftViewed = _lastViewedAtForEntry(left) ?? DateTime.fromMillisecondsSinceEpoch(0);
        return rightViewed.compareTo(leftViewed);
      });
    final lightlyViewed = viewed.toList(growable: false)
      ..sort((left, right) {
        final countCompare = _viewCountForEntry(left).compareTo(_viewCountForEntry(right));
        if (countCompare != 0) {
          return countCompare;
        }
        final leftViewed = _lastViewedAtForEntry(left) ?? DateTime.fromMillisecondsSinceEpoch(0);
        final rightViewed = _lastViewedAtForEntry(right) ?? DateTime.fromMillisecondsSinceEpoch(0);
        return leftViewed.compareTo(rightViewed);
      });
    final unread = entries
        .where((entry) => _viewCountForEntry(entry) == 0)
        .toList(growable: false)
      ..sort((left, right) => _addedAtForEntry(right).compareTo(_addedAtForEntry(left)));

    return <_WebHomeSectionData>[
      _WebHomeSectionData(
        title: '新着',
        subtitle: '最近ライブラリに追加された PDF です。',
        icon: Icons.schedule_outlined,
        entries: recentlyAdded.take(12).toList(growable: false),
      ),
      _WebHomeSectionData(
        title: 'よく見る作品',
        subtitle: '閲覧回数の多い PDF をまとめています。',
        icon: Icons.local_fire_department_outlined,
        entries: frequentlyViewed.take(12).toList(growable: false),
      ),
      _WebHomeSectionData(
        title: '少しだけ見た作品',
        subtitle: '少数回だけ開いた PDF です。',
        icon: Icons.visibility_outlined,
        entries: lightlyViewed.take(12).toList(growable: false),
      ),
      _WebHomeSectionData(
        title: '未読',
        subtitle: 'まだ開いていない PDF です。',
        icon: Icons.mark_email_unread_outlined,
        entries: unread.take(12).toList(growable: false),
      ),
    ];
  }

  Future<void> _openPdfFromHome(WebRemoteEntry entry) async {
    setState(() {
      _selectedEntry = entry;
    });
    await _openPdfViewerPage(entry);
  }

  Widget _buildHomePane() {
    if (_client == null) {
      return _buildInfoCard(
        'ホーム',
        'ホスト API に接続すると PDF ライブラリの概要を表示できます。',
        Colors.white70,
      );
    }

    final entries = _homeEntries;
    final unreadCount = entries.where((entry) => _viewCountForEntry(entry) == 0).length;
    final viewedCount = entries.where((entry) => _viewCountForEntry(entry) > 0).length;
    final recentCount = entries
        .where(
          (entry) => _addedAtForEntry(entry).isAfter(
            DateTime.now().toLocal().subtract(const Duration(days: 7)),
          ),
        )
        .length;
    final sections = _buildHomeSections(entries);

    return RefreshIndicator(
      onRefresh: () async {
        await _refreshHomeEntries(force: true);
        if (_searchController.text.trim().isEmpty) {
          await _loadEntries();
        }
      },
      child: ListView(
        padding: EdgeInsets.all(MediaQuery.of(context).size.width < 720 ? 10 : 16),
        children: <Widget>[
          _WebHomeHeroCard(
            totalCount: entries.length,
            unreadCount: unreadCount,
            viewedCount: viewedCount,
            recentCount: recentCount,
            isBusy: _homeLoading || _isConnecting || _actionBusy,
            onBrowseAll: () {
              setState(() {
                _surface = _WebRemoteSurface.browse;
              });
              unawaited(_loadEntries());
            },
            onRefresh: () => _refreshHomeEntries(force: true),
          ),
          const SizedBox(height: 16),
          if (_homeLoading && entries.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
            )
          else if (_homeErrorMessage != null && entries.isEmpty)
            _buildInfoCard('ホームエラー', _homeErrorMessage!, Colors.red.shade200)
          else if (entries.isEmpty)
            _buildInfoCard(
              'PDF がありません',
              '接続中のライブラリに、ホームへ表示できる PDF がまだありません。',
              Colors.white70,
            )
          else
            ...sections.map(
              (section) => Padding(
                padding: const EdgeInsets.only(bottom: 18),
                child: _WebHomeSection(
                  section: section,
                  client: _client,
                  onOpen: _openPdfFromHome,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBrowserPane(bool splitView) {
    final parentFolder =
        _selectedFolderRaw == null ? null : _parentFolderWithinLibrary(_selectedFolderRaw!);
    final currentFolderRaw = _selectedFolderRaw ?? _libraryRoot?.raw;
    return _buildList(
      splitView,
      currentFolderRaw: currentFolderRaw,
      parentFolder: parentFolder,
    );
  }

  Widget _buildBrowserControls({
    required String? currentFolderRaw,
    required String? parentFolder,
  }) {
    final rootLabel = _currentFolderLabel(currentFolderRaw);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _PinnedBrowserSearchBar(
          searchController: _searchController,
          isLoading: _isLoading,
          onSearch: _loadEntries,
        ),
        const SizedBox(height: 12),
        _ResponsiveBrowserHeader(
          folderName: '$rootLabel / PDF',
          folderPath: currentFolderRaw,
          itemCount: _entries.length,
          searchController: _searchController,
          isLoading: _isLoading,
          actionsBusy: _actionBusy,
          onGoRoot:
              currentFolderRaw == null ||
                      _libraryRoot == null ||
                      _isSamePath(currentFolderRaw, _libraryRoot!.raw)
                  ? null
                  : () => _selectFolder(_libraryRoot!.raw),
          parentFolderAvailable: parentFolder != null,
          onSearch: _loadEntries,
          onGoParent: parentFolder == null ? null : () => _selectFolder(parentFolder),
          onImportUrl:
              _client == null || _selectedFolderRaw == null || _actionBusy
                  ? null
                  : _importUrlToCurrentFolder,
          onOrganizeFolder:
              _client == null || _selectedFolderRaw == null || _actionBusy
                  ? null
                  : _organizeCurrentFolder,
          onRescan:
              _client == null || _actionBusy
                  ? null
                  : _requestRescanCurrentFolder,
          filter: _filter,
          onFilterChanged: (filter) {
            setState(() {
              _filter = filter;
            });
            _loadEntries();
          },
          showSearchField: false,
        ),
        const SizedBox(height: 12),
        _BrowserDisplayModeCard(
          mode: _browserDisplayMode,
          onChanged: _setBrowserDisplayMode,
        ),
      ],
    );
  }

  Widget _buildList(
    bool splitView, {
    required String? currentFolderRaw,
    required String? parentFolder,
  }) {
    if (_browserDisplayMode == _WebBrowserDisplayMode.tile) {
      return _buildSingleTileList(
        splitView,
        currentFolderRaw: currentFolderRaw,
        parentFolder: parentFolder,
      );
    }

    if (_browserDisplayMode == _WebBrowserDisplayMode.threeUp) {
      return _buildThreeUpGrid(
        splitView,
        currentFolderRaw: currentFolderRaw,
        parentFolder: parentFolder,
      );
    }

    final compact = MediaQuery.of(context).size.width < 720;
    final listPadding = EdgeInsets.all(compact ? 10 : 16);
    final controls = _buildBrowserControls(
      currentFolderRaw: currentFolderRaw,
      parentFolder: parentFolder,
    );

    return RefreshIndicator(
      onRefresh: _loadEntries,
      child:
          _entries.isEmpty && !_isLoading
              ? ListView(
                padding: listPadding,
                children: <Widget>[
                  controls,
                  const SizedBox(height: 12),
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Column(
                        children: <Widget>[
                          Icon(Icons.travel_explore, size: 52, color: Colors.white30),
                          SizedBox(height: 12),
                          Text(
                            'この表示では項目が見つかりません。',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              )
              : ListView.separated(
                padding: listPadding,
                itemCount: _entries.length + 1,
                separatorBuilder:
                    (context, index) => SizedBox(height: compact ? 10 : 12),
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return controls;
                  }
                  final entry = _entries[index - 1];
                  final selected = _selectedEntry?.stableId == entry.stableId;
                  return _EntryCard(
                    key: ValueKey<String>(entry.stableId),
                    client: _client,
                    entry: entry,
                    selected: selected,
                    onTap: () => _handleEntryTap(entry, splitView: splitView),
                    folderName: _folderName,
                    onApplyTagQuery: _applyTagQuery,
                  );
                },
              ),
    );
  }

  Widget _buildSingleTileList(
    bool splitView, {
    required String? currentFolderRaw,
    required String? parentFolder,
  }) {
    final compact = MediaQuery.of(context).size.width < 720;
    final listPadding = EdgeInsets.all(compact ? 10 : 16);
    final controls = _buildBrowserControls(
      currentFolderRaw: currentFolderRaw,
      parentFolder: parentFolder,
    );

    return RefreshIndicator(
      onRefresh: _loadEntries,
      child:
          _entries.isEmpty && !_isLoading
              ? ListView(
                padding: listPadding,
                children: <Widget>[
                  controls,
                  const SizedBox(height: 12),
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Column(
                        children: <Widget>[
                          Icon(Icons.travel_explore, size: 52, color: Colors.white30),
                          SizedBox(height: 12),
                          Text(
                            'この表示では項目が見つかりません。',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              )
              : ListView.separated(
                padding: listPadding,
                itemCount: _entries.length + 1,
                separatorBuilder:
                    (context, index) => SizedBox(height: compact ? 10 : 14),
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return controls;
                  }
                  final entry = _entries[index - 1];
                  final selected = _selectedEntry?.stableId == entry.stableId;
                  return _EntrySingleTileCard(
                    key: ValueKey<String>('tile-${entry.stableId}'),
                    client: _client,
                    entry: entry,
                    selected: selected,
                    onTap: () => _handleEntryTap(entry, splitView: splitView),
                    folderName: _folderName,
                  );
                },
              ),
    );
  }

  Widget _buildThreeUpGrid(
    bool splitView, {
    required String? currentFolderRaw,
    required String? parentFolder,
  }) {
    final compact = MediaQuery.of(context).size.width < 720;
    final listPadding = EdgeInsets.all(compact ? 10 : 16);
    final controls = _buildBrowserControls(
      currentFolderRaw: currentFolderRaw,
      parentFolder: parentFolder,
    );

    return RefreshIndicator(
      onRefresh: _loadEntries,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final contentWidth =
              (constraints.maxWidth - listPadding.horizontal).clamp(
                0.0,
                double.infinity,
              );
          final columns = _browserGridColumnCount(contentWidth.toDouble());

          return CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: <Widget>[
              SliverPadding(
                padding: listPadding,
                sliver: SliverToBoxAdapter(child: controls),
              ),
              if (_entries.isEmpty)
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    listPadding.left,
                    12,
                    listPadding.right,
                    listPadding.bottom,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: _isLoading
                        ? const Card(
                            child: Padding(
                              padding: EdgeInsets.all(24),
                              child: Center(child: CircularProgressIndicator()),
                            ),
                          )
                        : const Card(
                            child: Padding(
                              padding: EdgeInsets.all(24),
                              child: Column(
                                children: <Widget>[
                                  Icon(
                                    Icons.travel_explore,
                                    size: 52,
                                    color: Colors.white30,
                                  ),
                                  SizedBox(height: 12),
                                  Text(
                                    'この表示では項目が見つかりません。',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(color: Colors.white70),
                                  ),
                                ],
                              ),
                            ),
                          ),
                  ),
                )
              else
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    listPadding.left,
                    12,
                    listPadding.right,
                    listPadding.bottom,
                  ),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      mainAxisSpacing: compact ? 8 : 16,
                      crossAxisSpacing: compact ? 8 : 16,
                      childAspectRatio: compact ? 0.67 : 0.70,
                    ),
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final entry = _entries[index];
                      final selected =
                          _selectedEntry?.stableId == entry.stableId;
                      return _EntryGridTileCard(
                        key: ValueKey<String>('grid-${entry.stableId}'),
                        client: _client,
                        entry: entry,
                        selected: selected,
                        onTap: () => _handleEntryTap(entry, splitView: splitView),
                      );
                    }, childCount: _entries.length),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildDetailPane() {
    if (_client == null) {
      return _buildInfoCard(
        'Web 閲覧',
        '左側で API URL とトークンを設定すると、ブラウザからリモートの PDF / 画像を開けます。',
        Colors.white70,
      );
    }
    if (_selectedEntry == null) {
      return Column(
        children: <Widget>[
          _buildInfoCard(
            '詳細表示',
            '一覧から画像を選ぶとここに詳細を表示し、PDF は専用の表示ページへ開けます。',
            Colors.white70,
          ),
          const SizedBox(height: 16),
          _buildUnsupportedFeaturesCard(),
        ],
      );
    }
    return WebMediaDetailView(
      client: _client!,
      entry: _selectedEntry!,
      onApplyTagQuery: _applyTagQuery,
      onOpenPdfViewerPage:
          _selectedEntry!.isPdf ? () => _openPdfViewerPage(_selectedEntry!) : null,
    );
  }

  Widget _buildInfoCard(String title, String message, Color color) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            Text(message, style: TextStyle(color: color)),
          ],
        ),
      ),
    );
  }

  Widget _buildUnsupportedFeaturesCard() {
    Widget bullet(String text) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('- ', style: TextStyle(color: Colors.white70)),
            Expanded(
              child: Text(text, style: const TextStyle(color: Colors.white70)),
            ),
          ],
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Web の注意点',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            bullet('ローカル Library の直接追加、フォルダ選択、端末ファイルの一括読み込みには未対応です'),
            bullet('Host API の構築やローカル DB の保守は引き続きネイティブ側の役割です'),
            bullet('URL 取り込みはホストへ依頼できますが、ブラウザ端末のローカル cookie / URL 一覧ファイル参照には未対応です'),
            bullet('PDF は Web 側でのページ描画に依存するため、新しいタブ表示と詳細表示で挙動差が出る場合があります'),
            bullet('HTTPS の Web ページから HTTP API へはブラウザ制約で接続できません'),
          ],
        ),
      ),
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('Web 未対応機能', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            bullet('ローカル Library の直接参照、フォルダ追加、ホスト取込み'),
            bullet('Host API サーバーの起動 / 停止、ローカル DB の編集'),
            bullet('ファイル名変更、削除、タグ編集、URL 取込みなどの書き込み操作'),
            bullet('ネイティブ版と同等の PDF ビューア全機能。Web ではページ画像プレビュー、同じタブ内の PDF 表示ページ、別タブ表示を提供'),
            bullet('HTTPS の Web ページから HTTP API へはブラウザ制限で接続できません'),
          ],
        ),
      ),
    );
  }

  String _formatDateTime(DateTime? value) {
    if (value == null) return '未取得';
    final local = value.toLocal();
    final two = (int number) => number.toString().padLeft(2, '0');
    return '${local.year}/${two(local.month)}/${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }
}

class _WebHomeSectionData {
  final String title;
  final String subtitle;
  final IconData icon;
  final List<WebRemoteEntry> entries;

  const _WebHomeSectionData({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.entries,
  });
}

class _WebHomeHeroCard extends StatelessWidget {
  final int totalCount;
  final int unreadCount;
  final int viewedCount;
  final int recentCount;
  final bool isBusy;
  final VoidCallback onBrowseAll;
  final Future<void> Function() onRefresh;

  const _WebHomeHeroCard({
    required this.totalCount,
    required this.unreadCount,
    required this.viewedCount,
    required this.recentCount,
    required this.isBusy,
    required this.onBrowseAll,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                const Text(
                  'PDF ホーム',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                ),
                if (isBusy)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              '新着、未読、よく見る PDF をここからまとめて確認できます。',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: <Widget>[
                _WebHomeMetricChip(
                  label: '総PDF数',
                  value: '$totalCount',
                  icon: Icons.picture_as_pdf_outlined,
                ),
                _WebHomeMetricChip(
                  label: '未読',
                  value: '$unreadCount',
                  icon: Icons.mark_email_unread_outlined,
                ),
                _WebHomeMetricChip(
                  label: '既読',
                  value: '$viewedCount',
                  icon: Icons.visibility_outlined,
                ),
                _WebHomeMetricChip(
                  label: '7日以内',
                  value: '$recentCount',
                  icon: Icons.schedule_outlined,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: onBrowseAll,
                  icon: const Icon(Icons.grid_view_rounded),
                  label: const Text('PDF一覧へ'),
                ),
                OutlinedButton.icon(
                  onPressed: isBusy ? null : () => onRefresh(),
                  icon: const Icon(Icons.refresh),
                  label: const Text('ホームを更新'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _WebHomeMetricChip extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _WebHomeMetricChip({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 140,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF141922),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 18, color: Colors.white70),
          const SizedBox(height: 10),
          Text(
            value,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(color: Colors.white60)),
        ],
      ),
    );
  }
}

class _WebHomeSection extends StatelessWidget {
  final _WebHomeSectionData section;
  final WebRemoteApiClient? client;
  final Future<void> Function(WebRemoteEntry entry) onOpen;

  const _WebHomeSection({
    required this.section,
    required this.client,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.of(context).size.width < 720;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(section.icon, color: Colors.white70),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    section.title,
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    section.subtitle,
                    style: const TextStyle(color: Colors.white60),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (section.entries.isEmpty)
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Text(
                'このセクションに一致する PDF はまだありません。',
                style: const TextStyle(color: Colors.white60),
              ),
            ),
          )
        else
          SizedBox(
            height: compact ? 308 : 332,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: section.entries.length,
              separatorBuilder: (context, index) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final entry = section.entries[index];
                return _WebHomePdfCard(
                  client: client,
                  entry: entry,
                  compact: compact,
                  onTap: () => onOpen(entry),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _WebHomePdfCard extends StatelessWidget {
  final WebRemoteApiClient? client;
  final WebRemoteEntry entry;
  final bool compact;
  final Future<void> Function() onTap;

  const _WebHomePdfCard({
    required this.client,
    required this.entry,
    required this.compact,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final addedAt = (entry.stats?.addedAt ?? entry.modifiedAt)?.toLocal();
    final lastViewedAt = entry.stats?.lastViewedAt?.toLocal();
    final viewCount = entry.stats?.viewCount ?? 0;

    return SizedBox(
      width: compact ? 236 : 270,
      child: Card(
        margin: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => onTap(),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Center(
                  child: _RemoteThumbnail(
                    client: client,
                    entry: entry,
                    width: compact ? 184 : 214,
                    height: compact ? 150 : 170,
                    borderRadius: 12,
                    backgroundColor: const Color(0xFF151721),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _entryDisplayTitle(entry),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  entry.folderRaw,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white60),
                ),
                const SizedBox(height: 10),
                _WebHomeStatLine(
                  label: '追加',
                  value: _formatBrowseDateTime(addedAt),
                ),
                _WebHomeStatLine(
                  label: '閲覧',
                  value: '$viewCount',
                ),
                _WebHomeStatLine(
                  label: '最終',
                  value: lastViewedAt == null ? '未読' : _formatBrowseDateTime(lastViewedAt),
                ),
                const Spacer(),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed: () => onTap(),
                    icon: const Icon(Icons.menu_book_rounded),
                    label: const Text('開く'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WebHomeStatLine extends StatelessWidget {

  final String label;
  final String value;

  const _WebHomeStatLine({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 52,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white54, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }
}

class _BrowserHeader extends StatelessWidget {
  final String? folderName;
  final int itemCount;
  final TextEditingController searchController;
  final bool isLoading;
  final bool actionsBusy;
  final bool parentFolderAvailable;
  final Future<void> Function() onSearch;
  final VoidCallback? onGoParent;
  final VoidCallback? onImportUrl;
  final VoidCallback? onOrganizeFolder;
  final VoidCallback? onRescan;
  final _WebMediaFilter filter;
  final ValueChanged<_WebMediaFilter> onFilterChanged;

  const _BrowserHeader({
    required this.folderName,
    required this.itemCount,
    required this.searchController,
    required this.isLoading,
    required this.actionsBusy,
    required this.parentFolderAvailable,
    required this.onSearch,
    required this.onGoParent,
    required this.onImportUrl,
    required this.onOrganizeFolder,
    required this.onRescan,
    required this.filter,
    required this.onFilterChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                if (folderName != null)
                  Chip(
                    avatar: const Icon(Icons.folder_open, size: 18),
                    label: Text(folderName!),
                  ),
                if (parentFolderAvailable)
                  OutlinedButton.icon(
                    onPressed: onGoParent,
                    icon: const Icon(Icons.arrow_upward),
                    label: const Text('一つ上へ'),
                  ),
                Text('$itemCount 件', style: const TextStyle(color: Colors.white60)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: searchController,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => onSearch(),
                    decoration: const InputDecoration(
                      labelText: '検索',
                      hintText: 'artist:"作家名"  type:pdf  #tag  untagged',
                      prefixIcon: Icon(Icons.search),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: isLoading ? null : onSearch,
                  child: const Text('検索'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children:
                  _WebMediaFilter.values
                      .map(
                        (entry) => ChoiceChip(
                          label: Text(entry.label),
                          selected: filter == entry,
                          onSelected: (_) => onFilterChanged(entry),
                        ),
                      )
                      .toList(growable: false),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: actionsBusy ? null : onImportUrl,
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('URL取込'),
                ),
                OutlinedButton.icon(
                  onPressed: actionsBusy ? null : onOrganizeFolder,
                  icon: const Icon(Icons.auto_fix_high_outlined),
                  label: const Text('整理'),
                ),
                OutlinedButton.icon(
                  onPressed: actionsBusy ? null : onRescan,
                  icon: const Icon(Icons.refresh),
                  label: const Text('再スキャン'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

enum _BrowserHeaderMenuAction {
  goRoot,
  goParent,
  importUrl,
  organize,
  rescan,
}

class _ResponsiveBrowserHeader extends StatelessWidget {
  final String folderName;
  final String? folderPath;
  final int itemCount;
  final TextEditingController searchController;
  final bool isLoading;
  final bool actionsBusy;
  final VoidCallback? onGoRoot;
  final bool parentFolderAvailable;
  final Future<void> Function() onSearch;
  final VoidCallback? onGoParent;
  final VoidCallback? onImportUrl;
  final VoidCallback? onOrganizeFolder;
  final VoidCallback? onRescan;
  final _WebMediaFilter filter;
  final ValueChanged<_WebMediaFilter> onFilterChanged;
  final bool showSearchField;

  const _ResponsiveBrowserHeader({
    required this.folderName,
    required this.folderPath,
    required this.itemCount,
    required this.searchController,
    required this.isLoading,
    required this.actionsBusy,
    required this.onGoRoot,
    required this.parentFolderAvailable,
    required this.onSearch,
    required this.onGoParent,
    required this.onImportUrl,
    required this.onOrganizeFolder,
    required this.onRescan,
    required this.filter,
    required this.onFilterChanged,
    this.showSearchField = true,
  });

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final compact = mediaQuery.size.width < 720;
    final keyboardVisible = mediaQuery.viewInsets.bottom > 0;
    final title = folderName;
    final menuActions = <PopupMenuEntry<_BrowserHeaderMenuAction>>[
      if (onGoRoot != null)
        const PopupMenuItem<_BrowserHeaderMenuAction>(
          value: _BrowserHeaderMenuAction.goRoot,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.home_outlined),
            title: Text('ライブラリ直下'),
          ),
        ),
      if (parentFolderAvailable)
        const PopupMenuItem<_BrowserHeaderMenuAction>(
          value: _BrowserHeaderMenuAction.goParent,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.arrow_upward),
            title: Text('親フォルダ'),
          ),
        ),
      if (onImportUrl != null)
        const PopupMenuItem<_BrowserHeaderMenuAction>(
          value: _BrowserHeaderMenuAction.importUrl,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.download_outlined),
            title: Text('URL取込'),
          ),
        ),
      if (onOrganizeFolder != null)
        const PopupMenuItem<_BrowserHeaderMenuAction>(
          value: _BrowserHeaderMenuAction.organize,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.auto_fix_high_outlined),
            title: Text('整理'),
          ),
        ),
      if (onRescan != null)
        const PopupMenuItem<_BrowserHeaderMenuAction>(
          value: _BrowserHeaderMenuAction.rescan,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.refresh),
            title: Text('再スキャン'),
          ),
        ),
    ];

    void handleMenu(_BrowserHeaderMenuAction action) {
      switch (action) {
        case _BrowserHeaderMenuAction.goRoot:
          onGoRoot?.call();
          break;
        case _BrowserHeaderMenuAction.goParent:
          onGoParent?.call();
          break;
        case _BrowserHeaderMenuAction.importUrl:
          onImportUrl?.call();
          break;
        case _BrowserHeaderMenuAction.organize:
          onOrganizeFolder?.call();
          break;
        case _BrowserHeaderMenuAction.rescan:
          onRescan?.call();
          break;
      }
    }

    if (compact) {
      return Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: EdgeInsets.all(keyboardVisible ? 10 : 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (showSearchField) ...<Widget>[
                TextField(
                  controller: searchController,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => onSearch(),
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: '検索',
                    hintText: 'artist:"作家名"  type:pdf  #tag',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: IconButton(
                      onPressed: isLoading ? null : onSearch,
                      icon: const Icon(Icons.arrow_forward),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A2432),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '$itemCount',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (menuActions.isNotEmpty)
                    PopupMenuButton<_BrowserHeaderMenuAction>(
                      enabled: !actionsBusy,
                      onSelected: handleMenu,
                      itemBuilder: (context) => menuActions,
                      icon: const Icon(Icons.more_horiz),
                    ),
                ],
              ),
              if (folderPath != null && folderPath!.trim().isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  folderPath!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white60),
                  ),
                ],
            ],
          ),
        ),
      );
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (showSearchField) ...<Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: searchController,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => onSearch(),
                      decoration: const InputDecoration(
                        labelText: '検索',
                        hintText: 'artist:"作家名"  type:pdf  #tag  untagged',
                        prefixIcon: Icon(Icons.search),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: isLoading ? null : onSearch,
                    child: const Text('検索'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                Chip(
                  avatar: const Icon(Icons.folder_open, size: 18),
                  label: Text(title),
                ),
                if (folderPath != null && folderPath!.trim().isNotEmpty)
                  Chip(
                    avatar: const Icon(Icons.route_outlined, size: 18),
                    label: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 360),
                      child: Text(
                        folderPath!,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                if (onGoRoot != null)
                  OutlinedButton.icon(
                    onPressed: onGoRoot,
                    icon: const Icon(Icons.home_outlined),
                    label: const Text('ライブラリ直下'),
                  ),
                if (parentFolderAvailable)
                  OutlinedButton.icon(
                    onPressed: onGoParent,
                    icon: const Icon(Icons.arrow_upward),
                    label: const Text('親フォルダ'),
                  ),
                Text(
                  '$itemCount 件',
                  style: const TextStyle(color: Colors.white60),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: actionsBusy ? null : onImportUrl,
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('URL取込'),
                ),
                OutlinedButton.icon(
                  onPressed: actionsBusy ? null : onOrganizeFolder,
                  icon: const Icon(Icons.auto_fix_high_outlined),
                  label: const Text('整理'),
                ),
                OutlinedButton.icon(
                  onPressed: actionsBusy ? null : onRescan,
                  icon: const Icon(Icons.refresh),
                  label: const Text('再スキャン'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PinnedBrowserSearchBar extends StatelessWidget {
  final TextEditingController searchController;
  final bool isLoading;
  final Future<void> Function() onSearch;

  const _PinnedBrowserSearchBar({
    required this.searchController,
    required this.isLoading,
    required this.onSearch,
  });

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.of(context).size.width < 720;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsets.all(compact ? 10 : 14),
        child: Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: searchController,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => onSearch(),
                decoration: InputDecoration(
                  isDense: compact,
                  labelText: '検索',
                  hintText: 'artist:"作家名"  type:pdf  #tag  untagged',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon:
                      compact
                          ? IconButton(
                            onPressed: isLoading ? null : onSearch,
                            icon: const Icon(Icons.arrow_forward),
                          )
                          : null,
                ),
              ),
            ),
            if (!compact) ...<Widget>[
              const SizedBox(width: 12),
              FilledButton(
                onPressed: isLoading ? null : onSearch,
                child: const Text('検索'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _formatBrowseDateTime(DateTime? value) {
  if (value == null) {
    return '未取得';
  }
  final local = value.toLocal();
  final two = (int number) => number.toString().padLeft(2, '0');
  return '${local.year}/${two(local.month)}/${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

String _formatBrowseBytes(int? bytes) {
  if (bytes == null) {
    return '未取得';
  }
  if (bytes < 1024) {
    return '$bytes B';
  }
  const units = <String>['KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var index = -1;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index += 1;
  }
  final digits = value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[index]}';
}

String _filterLabel(_WebMediaFilter filter) {
  switch (filter) {
    case _WebMediaFilter.pdf:
      return 'PDF';
  }
}

MediaKind _entryMediaKind(WebRemoteEntry entry) {
  if (entry.isFolder) {
    return MediaKind.folder;
  }
  return entry.isPdf ? MediaKind.pdf : MediaKind.image;
}

String _entryDisplayTitle(WebRemoteEntry entry) {
  return ItemNameService.formatMediaTitle(
    entry.displayName,
    kind: _entryMediaKind(entry),
  );
}

Color _entryAccentColor(WebRemoteEntry entry) {
  if (entry.isFolder) {
    return const Color(0xFF94A7BD);
  }
  const palette = <Color>[
    Color(0xFFD0A2A5),
    Color(0xFFD4B18E),
    Color(0xFFBF97C9),
    Color(0xFF96A9CC),
    Color(0xFF95B69A),
  ];
  final index = (entry.stableId.hashCode & 0x7fffffff) % palette.length;
  return palette[index];
}

class _BrowserDisplayModeCard extends StatelessWidget {
  final _WebBrowserDisplayMode mode;
  final ValueChanged<_WebBrowserDisplayMode> onChanged;

  const _BrowserDisplayModeCard({
    required this.mode,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.of(context).size.width < 720;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsets.all(compact ? 12 : 14),
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            Text(
              '表示モード',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            SegmentedButton<_WebBrowserDisplayMode>(
              showSelectedIcon: false,
              segments:
                  _WebBrowserDisplayMode.values
                      .map(
                        (candidate) => ButtonSegment<_WebBrowserDisplayMode>(
                          value: candidate,
                          icon: Icon(candidate.icon),
                          label: Text(
                            compact ? candidate.compactLabel : candidate.label,
                          ),
                        ),
                      )
                      .toList(growable: false),
              selected: <_WebBrowserDisplayMode>{mode},
              onSelectionChanged: (selection) {
                final next = selection.firstOrNull;
                if (next != null) {
                  onChanged(next);
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _EntryCard extends StatelessWidget {
  final WebRemoteApiClient? client;
  final WebRemoteEntry entry;
  final bool selected;
  final VoidCallback onTap;
  final String Function(String raw) folderName;
  final Future<void> Function(String query)? onApplyTagQuery;

  const _EntryCard({
    super.key,
    required this.client,
    required this.entry,
    required this.selected,
    required this.onTap,
    required this.folderName,
    this.onApplyTagQuery,
  });

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 920;
    final accent = _entryAccentColor(entry);
    final borderColor =
        selected ? Color.lerp(accent, const Color(0xFF4B2B33), 0.30)! : accent.withOpacity(0.58);
    final backgroundColor =
        selected ? const Color(0xFFFDF7F4) : const Color(0xFFF7F0EC);

    final preview = _EntryThumbnailStack(
      client: client,
      entry: entry,
      accent: accent,
      compact: compact,
    );
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _EntryTitleBand(
          entry: entry,
          accent: accent,
          selected: selected,
        ),
        const SizedBox(height: 8),
        _EntryMetadataSummary(
          client: client,
          entry: entry,
          accent: accent,
          folderName: folderName,
          onApplyTagQuery: onApplyTagQuery,
        ),
      ],
    );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: borderColor, width: selected ? 1.6 : 1),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: accent.withOpacity(selected ? 0.18 : 0.10),
                blurRadius: selected ? 24 : 18,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child:
              compact
                  ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: preview,
                      ),
                      const SizedBox(height: 16),
                      details,
                    ],
                  )
                  : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      preview,
                      const SizedBox(width: 22),
                      Expanded(child: details),
                      const SizedBox(width: 12),
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Icon(
                          entry.isFolder ? Icons.arrow_forward : Icons.chevron_right,
                          color: const Color(0xFF6E5354),
                        ),
                      ),
                    ],
                  ),
        ),
      ),
    );
  }
}

class _EntrySingleTileCard extends StatelessWidget {
  final WebRemoteApiClient? client;
  final WebRemoteEntry entry;
  final bool selected;
  final VoidCallback onTap;
  final String Function(String raw) folderName;

  const _EntrySingleTileCard({
    super.key,
    required this.client,
    required this.entry,
    required this.selected,
    required this.onTap,
    required this.folderName,
  });

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.of(context).size.width < 720;
    final accent = _entryAccentColor(entry);
    final borderColor =
        selected
            ? Color.lerp(accent, Colors.white, 0.24) ?? accent
            : Colors.white.withOpacity(0.10);
    final backgroundColor =
        selected ? const Color(0xFF192231) : const Color(0xFF131922);
    final folderLabel = folderName(entry.folderRaw);
    final updatedLabel = _formatBrowseDateTime(entry.modifiedAt);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: EdgeInsets.all(compact ? 12 : 16),
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: borderColor, width: selected ? 1.8 : 1),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: accent.withOpacity(selected ? 0.16 : 0.08),
                blurRadius: selected ? 24 : 18,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _RemoteThumbnail(
                client: client,
                entry: entry,
                width: compact ? 122 : 164,
                height: compact ? 174 : 228,
                borderRadius: 18,
                backgroundColor: const Color(0xFF0E141C),
              ),
              SizedBox(width: compact ? 12 : 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: accent.withOpacity(0.88),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Icon(
                                Icons.picture_as_pdf_outlined,
                                size: 14,
                                color: Color(0xFF2E2323),
                              ),
                              SizedBox(width: 4),
                              Text(
                                'PDF',
                                style: TextStyle(
                                  color: Color(0xFF2E2323),
                                  fontWeight: FontWeight.w800,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: Colors.white12),
                          ),
                          child: Text(
                            folderLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _entryDisplayTitle(entry),
                      maxLines: compact ? 3 : 4,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: compact ? 18 : 22,
                        fontWeight: FontWeight.w800,
                        height: 1.18,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      updatedLabel,
                      style: const TextStyle(
                        color: Colors.white60,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'クリックで詳細表示・閲覧へ進みます',
                      style: TextStyle(
                        color: accent.withOpacity(0.90),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EntryGridTileCard extends StatelessWidget {
  final WebRemoteApiClient? client;
  final WebRemoteEntry entry;
  final bool selected;
  final VoidCallback onTap;

  const _EntryGridTileCard({
    super.key,
    required this.client,
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = _entryAccentColor(entry);
    final borderColor =
        selected
            ? Color.lerp(accent, Colors.white, 0.22) ?? accent
            : Colors.white.withOpacity(0.10);
    final shadowColor = accent.withOpacity(selected ? 0.14 : 0.08);
    final radius = BorderRadius.circular(18);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          decoration: BoxDecoration(
            color: const Color(0xFF0E141C),
            borderRadius: radius,
            border: Border.all(color: borderColor, width: selected ? 1.8 : 1),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: shadowColor,
                blurRadius: selected ? 20 : 14,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(17),
            child: LayoutBuilder(
              builder: (context, constraints) {
                return _RemoteThumbnail(
                  client: client,
                  entry: entry,
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                  borderRadius: 17,
                  backgroundColor: const Color(0xFF0E141C),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _EntryHeader extends StatelessWidget {
  final WebRemoteEntry entry;
  final String Function(String raw) folderName;

  const _EntryHeader({
    required this.entry,
    required this.folderName,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          _entryDisplayTitle(entry),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            Chip(
              avatar: Icon(
                entry.isFolder
                    ? Icons.folder_outlined
                    : entry.isPdf
                    ? Icons.picture_as_pdf_outlined
                    : Icons.image_outlined,
                size: 18,
              ),
              label: Text(
                entry.isFolder ? 'フォルダ' : entry.isPdf ? 'PDF' : '画像',
              ),
            ),
            if (!entry.isFolder)
              Chip(
                avatar: const Icon(Icons.folder_open, size: 18),
                label: Text(folderName(entry.folderRaw)),
              ),
          ],
        ),
      ],
    );
  }
}

class _EntryMeta extends StatelessWidget {
  final WebRemoteEntry entry;

  const _EntryMeta({required this.entry});

  String _formatDateTime(DateTime? value) {
    if (value == null) {
      return '未取得';
    }
    final local = value.toLocal();
    final two = (int number) => number.toString().padLeft(2, '0');
    return '${local.year}/${two(local.month)}/${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  String _formatBytes(int? bytes) {
    if (bytes == null) {
      return '未取得';
    }
    if (bytes < 1024) {
      return '$bytes B';
    }
    const units = <String>['KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var index = -1;
    while (value >= 1024 && index < units.length - 1) {
      value /= 1024;
      index += 1;
    }
    final digits = value >= 100 ? 0 : 1;
    return '${value.toStringAsFixed(digits)} ${units[index]}';
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 58,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white60,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (entry.isFolder) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            entry.fullPath ?? entry.entryId,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 10),
          const Text(
            'タップするとこのフォルダへ移動します。',
            style: TextStyle(color: Colors.white60),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _row('場所', entry.folderRaw),
        _row('更新', _formatDateTime(entry.modifiedAt)),
        _row('サイズ', _formatBytes(entry.sizeBytes)),
      ],
    );
  }
}

class _EntryTitleBand extends StatelessWidget {
  final WebRemoteEntry entry;
  final Color accent;
  final bool selected;

  const _EntryTitleBand({
    required this.entry,
    required this.accent,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.of(context).size.width < 560;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: selected ? accent : accent.withOpacity(0.84),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        _entryDisplayTitle(entry),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: Color(0xFF362324),
          fontSize: compact ? 22 : 28,
          fontWeight: FontWeight.w800,
          height: 1.04,
        ),
      ),
    );
  }
}

class _EntryThumbnailStack extends StatelessWidget {
  final WebRemoteApiClient? client;
  final WebRemoteEntry entry;
  final Color accent;
  final bool compact;

  const _EntryThumbnailStack({
    required this.client,
    required this.entry,
    required this.accent,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    final veryCompact = MediaQuery.of(context).size.width < 560;
    final width = veryCompact ? 172.0 : compact ? 206.0 : 250.0;
    final height = veryCompact ? 196.0 : compact ? 230.0 : 280.0;
    final thumbWidth = veryCompact ? 110.0 : compact ? 134.0 : 164.0;
    final thumbHeight = veryCompact ? 150.0 : compact ? 188.0 : 228.0;

    if (entry.isFolder) {
      return _FolderPreviewPanel(
        client: client,
        entry: entry,
        accent: accent,
        width: width,
        height: height,
      );
    }

    Widget panel({
      required double left,
      required double top,
      required double angle,
      required Color color,
    }) {
      return Positioned(
        left: left,
        top: top,
        child: Transform.rotate(
          angle: angle,
          child: Container(
            width: thumbWidth,
            height: thumbHeight,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          panel(
            left: veryCompact ? 10 : 18,
            top: veryCompact ? 12 : 18,
            angle: -0.06,
            color: const Color(0xFF2A2734),
          ),
          panel(
            left: veryCompact ? 28 : 48,
            top: veryCompact ? 8 : 12,
            angle: 0.03,
            color: const Color(0xFF242230),
          ),
          panel(
            left: veryCompact ? 46 : 78,
            top: veryCompact ? 4 : 6,
            angle: -0.02,
            color: const Color(0xFF1D1B29),
          ),
          Positioned(
            left: veryCompact ? 52 : 84,
            top: veryCompact ? 22 : 38,
            child: _RemoteThumbnail(
              client: client,
              entry: entry,
              width: thumbWidth,
              height: thumbHeight,
              borderRadius: 10,
              backgroundColor: const Color(0xFF151721),
            ),
          ),
          Positioned(
            left: 10,
            right: 0,
            bottom: 0,
            child: Container(
              height: 18,
              decoration: BoxDecoration(
                color: accent.withOpacity(0.30),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FolderPreviewPanel extends StatefulWidget {
  final WebRemoteApiClient? client;
  final WebRemoteEntry entry;
  final Color accent;
  final double width;
  final double height;

  const _FolderPreviewPanel({
    required this.client,
    required this.entry,
    required this.accent,
    required this.width,
    required this.height,
  });

  @override
  State<_FolderPreviewPanel> createState() => _FolderPreviewPanelState();
}

class _FolderPreviewPanelState extends State<_FolderPreviewPanel> {
  Future<List<WebRemoteEntry>>? _previewFuture;

  @override
  void initState() {
    super.initState();
    _refreshPreview();
  }

  @override
  void didUpdateWidget(covariant _FolderPreviewPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.stableId != widget.entry.stableId ||
        oldWidget.client != widget.client) {
      _refreshPreview();
    }
  }

  void _refreshPreview() {
    final client = widget.client;
    final folderRaw = (widget.entry.fullPath ?? widget.entry.entryId).trim();
    if (client == null || folderRaw.isEmpty) {
      _previewFuture = null;
      return;
    }
    _previewFuture = _loadPreview(client, folderRaw);
  }

  Future<List<WebRemoteEntry>> _loadPreview(
    WebRemoteApiClient client,
    String folderRaw,
  ) async {
    final children = await client.listFolderChildren(folderRaw, limit: 24);
    final mediaEntries = children.where((entry) => !entry.isFolder).toList();
    mediaEntries.sort((left, right) {
      final leftModified = left.modifiedAt?.millisecondsSinceEpoch ?? 0;
      final rightModified = right.modifiedAt?.millisecondsSinceEpoch ?? 0;
      final modifiedCompare = rightModified.compareTo(leftModified);
      if (modifiedCompare != 0) {
        return modifiedCompare;
      }
      return left.displayName
          .toLowerCase()
          .compareTo(right.displayName.toLowerCase());
    });
    return mediaEntries.take(3).toList(growable: false);
  }

  Widget _frame(Widget child) {
    return Container(
      width: widget.width,
      height: widget.height,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF171A23),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white12),
      ),
      child: Stack(
        children: <Widget>[
          Positioned.fill(child: child),
          Positioned(
            left: 0,
            top: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: widget.accent.withOpacity(0.92),
                borderRadius: BorderRadius.circular(999),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.folder_open, size: 14, color: Color(0xFF352324)),
                  SizedBox(width: 4),
                  Text(
                    'フォルダ',
                    style: TextStyle(
                      color: Color(0xFF352324),
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _placeholder({Widget? child}) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF242633),
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.center,
      child:
          child ??
          const Icon(
            Icons.insert_drive_file_outlined,
            color: Colors.white38,
          ),
    );
  }

  Widget _grid(List<WebRemoteEntry> entries) {
    final lead = entries.first;
    final second = entries.length > 1 ? entries[1] : null;
    final third = entries.length > 2 ? entries[2] : null;

    return _frame(
      LayoutBuilder(
        builder: (context, constraints) {
          final gap = constraints.maxWidth < 190 ? 6.0 : 8.0;
          final mainWidth = constraints.maxWidth * 0.58;
          final sideWidth = (constraints.maxWidth - mainWidth - gap)
              .clamp(0.0, constraints.maxWidth);
          final sideHeight = ((constraints.maxHeight - gap) / 2)
              .clamp(0.0, constraints.maxHeight);

          return Row(
            children: <Widget>[
              _RemoteThumbnail(
                key: ValueKey<String>('folder-main-${lead.stableId}'),
                client: widget.client,
                entry: lead,
                width: mainWidth,
                height: constraints.maxHeight,
                borderRadius: 12,
                backgroundColor: const Color(0xFF12141B),
              ),
              SizedBox(width: gap),
              SizedBox(
                width: sideWidth,
                child: Column(
                  children: <Widget>[
                    if (second != null)
                      _RemoteThumbnail(
                        key: ValueKey<String>('folder-side-a-${second.stableId}'),
                        client: widget.client,
                        entry: second,
                        width: sideWidth,
                        height: sideHeight,
                        borderRadius: 12,
                        backgroundColor: const Color(0xFF12141B),
                      )
                    else
                      SizedBox(
                        width: sideWidth,
                        height: sideHeight,
                        child: _placeholder(),
                      ),
                    SizedBox(height: gap),
                    if (third != null)
                      _RemoteThumbnail(
                        key: ValueKey<String>('folder-side-b-${third.stableId}'),
                        client: widget.client,
                        entry: third,
                        width: sideWidth,
                        height: sideHeight,
                        borderRadius: 12,
                        backgroundColor: const Color(0xFF12141B),
                      )
                    else
                      SizedBox(
                        width: sideWidth,
                        height: sideHeight,
                        child: _placeholder(
                          child: const Icon(
                            Icons.picture_as_pdf_outlined,
                            color: Colors.white38,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final future = _previewFuture;
    if (future == null) {
      return _frame(
        _placeholder(
          child: const Icon(
            Icons.folder_copy_outlined,
            size: 42,
            color: Colors.white60,
          ),
        ),
      );
    }

    return FutureBuilder<List<WebRemoteEntry>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _frame(
            const Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final entries = snapshot.data ?? const <WebRemoteEntry>[];
        if (entries.isEmpty) {
          return _frame(
            _placeholder(
              child: const Icon(
                Icons.folder_copy_outlined,
                size: 42,
                color: Colors.white60,
              ),
            ),
          );
        }
        return _grid(entries);
      },
    );
  }
}

class _EntryMetadataSummary extends StatefulWidget {
  final WebRemoteApiClient? client;
  final WebRemoteEntry entry;
  final Color accent;
  final String Function(String raw) folderName;
  final Future<void> Function(String query)? onApplyTagQuery;

  const _EntryMetadataSummary({
    required this.client,
    required this.entry,
    required this.accent,
    required this.folderName,
    this.onApplyTagQuery,
  });

  @override
  State<_EntryMetadataSummary> createState() => _EntryMetadataSummaryState();
}

class _EntryMetadataSummaryState extends State<_EntryMetadataSummary> {
  late Future<_EntrySummaryData> _summaryFuture;

  @override
  void initState() {
    super.initState();
    _summaryFuture = _loadSummary();
  }

  @override
  void didUpdateWidget(covariant _EntryMetadataSummary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.stableId != widget.entry.stableId ||
        oldWidget.client != widget.client) {
      _summaryFuture = _loadSummary();
    }
  }

  Future<_EntrySummaryData> _loadSummary() async {
    if (widget.entry.isFolder ||
        widget.client == null ||
        widget.entry.mediaId == null) {
      return _EntrySummaryData.forFolder(widget.entry);
    }

    final mediaId = widget.entry.mediaId!;
    final metaFuture = widget.client!.fetchMediaMeta(mediaId);
    final tagsFuture = widget.client!.fetchItemTags(mediaId);
    final meta = await metaFuture;
    final tags = await tagsFuture;
    return _EntrySummaryData.fromRemoteData(
      entry: widget.entry,
      meta: meta,
      tags: tags,
    );
  }

  Widget _badge(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFFF4E3DE),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: widget.accent.withOpacity(0.36)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 15, color: const Color(0xFF654A4B)),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF4C3838),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value, {int maxLines = 1}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 86,
            child: Text(
              label,
              style: const TextStyle(
                color: Color(0xFF5D4747),
                fontWeight: FontWeight.w800,
                fontSize: 15,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF3E2E2E),
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tag(Tag tag) {
    final onPressed = widget.onApplyTagQuery;
    final label = tag.name.trim();
    if (label.isEmpty) {
      return const SizedBox.shrink();
    }
    if (onPressed == null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF908E95),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
      );
    }
    return ActionChip(
      onPressed: () => onPressed(WebSearchParser.formatTagQuery(tag)),
      backgroundColor: const Color(0xFF908E95),
      side: BorderSide.none,
      label: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _loadingBody(String folderLabel) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: widget.accent.withOpacity(0.36),
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Text(
            'メタデータを読み込み中...',
            style: TextStyle(
              color: Color(0xFF4F393A),
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            _badge(
              widget.entry.isFolder
                  ? Icons.folder_outlined
                  : widget.entry.isPdf
                  ? Icons.picture_as_pdf_outlined
                  : Icons.image_outlined,
              widget.entry.isFolder
                  ? 'フォルダ'
                  : widget.entry.isPdf
                  ? 'PDF'
                  : '画像',
            ),
            _badge(Icons.folder_open_outlined, folderLabel),
          ],
        ),
      ],
    );
  }

  Widget _errorBody(String folderLabel, Object error) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: widget.accent.withOpacity(0.36),
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Text(
            'メタデータの読み込みに失敗しました',
            style: TextStyle(
              color: Color(0xFF4F393A),
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            _badge(
              widget.entry.isPdf ? Icons.picture_as_pdf_outlined : Icons.image_outlined,
              widget.entry.isPdf ? 'PDF' : '画像',
            ),
            _badge(Icons.folder_open_outlined, folderLabel),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          error.toString(),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: Colors.red.shade400, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  Widget _contentBody(_EntrySummaryData data) {
    final folderLabel = widget.folderName(widget.entry.folderRaw);
    final badges = <Widget>[
      _badge(
        widget.entry.isFolder
            ? Icons.folder_outlined
            : widget.entry.isPdf
            ? Icons.picture_as_pdf_outlined
            : Icons.image_outlined,
        data.mediaType,
      ),
      _badge(Icons.folder_open_outlined, folderLabel),
    ];
    if (data.pageInfo != null) {
      badges.add(_badge(Icons.menu_book_outlined, data.pageInfo!));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: widget.accent.withOpacity(0.36),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            data.subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFF4F393A),
              fontWeight: FontWeight.w800,
              fontSize: 16,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: badges),
        const SizedBox(height: 14),
        if (data.isFolder) ...<Widget>[
          _row('場所', data.location, maxLines: 2),
          _row('更新', data.updatedAt),
          const SizedBox(height: 8),
          const Text(
            'タップするとこのフォルダを開きます',
            style: TextStyle(
              color: Color(0xFF6E5959),
              fontWeight: FontWeight.w600,
            ),
          ),
        ] else ...<Widget>[
          _row('作家', data.artist),
          _row('シリーズ', data.series),
          _row('種別', data.mediaType),
          _row('言語', data.language),
          _row('保存先', data.location, maxLines: 2),
          const SizedBox(height: 8),
          const Text(
            'タグ',
            style: TextStyle(
              color: Color(0xFF5D4747),
              fontWeight: FontWeight.w800,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 8),
          if (data.tags.isEmpty)
            const Text(
              'タグはまだありません',
              style: TextStyle(
                color: Color(0xFF6E5959),
                fontWeight: FontWeight.w600,
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final tag in data.tags) _tag(tag),
                if (data.extraTagCount > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF908E95),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '+${data.extraTagCount}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
        ],
        const SizedBox(height: 14),
        Wrap(
          spacing: 14,
          runSpacing: 8,
          children: <Widget>[
            Text(
              data.updatedAt,
              style: TextStyle(
                color: Color.lerp(widget.accent, const Color(0xFF7D5858), 0.20),
                fontWeight: FontWeight.w800,
                fontSize: 15,
              ),
            ),
            Text(
              data.sizeLabel,
              style: const TextStyle(
                color: Color(0xFF6E5959),
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final folderLabel = widget.folderName(widget.entry.folderRaw);
    return FutureBuilder<_EntrySummaryData>(
      future: _summaryFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _loadingBody(folderLabel);
        }
        if (snapshot.hasError) {
          return _errorBody(folderLabel, snapshot.error!);
        }
        final data = snapshot.data ?? _EntrySummaryData.forFolder(widget.entry);
        return _contentBody(data);
      },
    );
  }
}

class _EntrySummaryData {
  final bool isFolder;
  final String subtitle;
  final String artist;
  final String series;
  final String mediaType;
  final String language;
  final String location;
  final String updatedAt;
  final String sizeLabel;
  final String? pageInfo;
  final List<Tag> tags;
  final int extraTagCount;

  const _EntrySummaryData({
    required this.isFolder,
    required this.subtitle,
    required this.artist,
    required this.series,
    required this.mediaType,
    required this.language,
    required this.location,
    required this.updatedAt,
    required this.sizeLabel,
    required this.pageInfo,
    required this.tags,
    required this.extraTagCount,
  });

  factory _EntrySummaryData.forFolder(WebRemoteEntry entry) {
    final location = (entry.fullPath ?? entry.entryId).trim();
    return _EntrySummaryData(
      isFolder: true,
      subtitle: 'Open folder',
      artist: '未設定',
      series: '未設定',
      mediaType: 'フォルダ',
      language: '未設定',
      location: location.isEmpty ? entry.folderRaw : location,
      updatedAt: _formatBrowseDateTime(entry.modifiedAt),
      sizeLabel: '-',
      pageInfo: null,
      tags: const <Tag>[],
      extraTagCount: 0,
    );
  }

  factory _EntrySummaryData.fromRemoteData({
    required WebRemoteEntry entry,
    required WebRemoteMediaMeta meta,
    required List<Tag> tags,
  }) {
    List<String> valuesFor(TagCategory category) {
      final seen = <String>{};
      final out = <String>[];
      for (final tag in tags) {
        if (tag.category != category) {
          continue;
        }
        final value = tag.name.trim();
        if (value.isEmpty || !seen.add(value.toLowerCase())) {
          continue;
        }
        out.add(value);
      }
      return out;
    }

    String joinOrFallback(List<String> values, {String fallback = '未設定'}) {
      if (values.isEmpty) {
        return fallback;
      }
      return values.take(2).join(' / ');
    }

    String resolveLanguage(List<Tag> values) {
      final normalized = values
          .map((tag) => tag.name.trim().toLowerCase())
          .where((name) => name.isNotEmpty)
          .toList(growable: false);
      bool hasLanguage(Iterable<String> keywords) {
        return normalized.any(
          (name) => keywords.any((keyword) => name.contains(keyword)),
        );
      }

      if (hasLanguage(const <String>['japanese'])) {
        return '日本語';
      }
      if (hasLanguage(const <String>['english'])) {
        return '英語';
      }
      if (hasLanguage(const <String>['chinese'])) {
        return '中国語';
      }
      if (hasLanguage(const <String>['korean'])) {
        return '韓国語';
      }
      return '未設定';
    }

    final artists = valuesFor(TagCategory.artist);
    final seriesValues = valuesFor(TagCategory.series);
    final mediaTypeValues = valuesFor(TagCategory.mediaType);
    final tagCandidates = <Tag>[];
    final seenTags = <String>{};
    for (final tag in tags) {
      if (tag.category == TagCategory.mediaType) {
        continue;
      }
      final label = tag.name.trim();
      final key = '${tag.category.name}\u0000${label.toLowerCase()}';
      if (label.isEmpty || !seenTags.add(key)) {
        continue;
      }
      tagCandidates.add(Tag(name: label, category: tag.category));
    }

    final subtitle =
        artists.firstOrNull ??
        seriesValues.firstOrNull ??
        (entry.folderRaw.trim().isEmpty ? _entryDisplayTitle(entry) : entry.folderRaw);
    final pageInfo =
        entry.isPdf && meta.pageCount != null && meta.pageCount! > 0
            ? '${meta.pageCount} pages'
            : null;

    return _EntrySummaryData(
      isFolder: false,
      subtitle: subtitle,
      artist: joinOrFallback(artists),
      series: joinOrFallback(seriesValues),
      mediaType:
          mediaTypeValues.firstOrNull ??
          (entry.isPdf ? 'PDF' : entry.isImage ? '画像' : 'メディア'),
      language: resolveLanguage(tags),
      location: entry.folderRaw,
      updatedAt: _formatBrowseDateTime(meta.modifiedAt ?? entry.modifiedAt),
      sizeLabel: _formatBrowseBytes(meta.sizeBytes ?? entry.sizeBytes),
      pageInfo: pageInfo,
      tags: tagCandidates.take(9).toList(growable: false),
      extraTagCount: tagCandidates.length > 9 ? tagCandidates.length - 9 : 0,
    );
  }
}

class WebMediaDetailView extends StatefulWidget {
  final WebRemoteApiClient client;
  final WebRemoteEntry entry;
  final Future<void> Function(String query) onApplyTagQuery;
  final VoidCallback? onOpenPdfViewerPage;

  const WebMediaDetailView({
    super.key,
    required this.client,
    required this.entry,
    required this.onApplyTagQuery,
    this.onOpenPdfViewerPage,
  });

  @override
  State<WebMediaDetailView> createState() => _WebMediaDetailViewState();
}

class _WebMediaDetailViewState extends State<WebMediaDetailView> {
  late Future<List<Tag>> _tagsFuture;
  late Future<WebRemoteMediaMeta> _metaFuture;
  late Future<Uint8List> _imageFuture;
  Uint8List? _pdfPageBytes;
  String? _pdfPageError;
  int _pdfPageNo = 1;
  int? _pdfTotalPages;
  bool _loadingPdfPage = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant WebMediaDetailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.stableId != widget.entry.stableId) {
      _refresh();
    }
  }

  void _refresh() {
    final mediaId = widget.entry.mediaId?.trim();
    final missingMediaIdError = StateError(
      'Missing mediaId for ${widget.entry.displayName}',
    );
    if (mediaId == null || mediaId.isEmpty) {
      _tagsFuture = Future<List<Tag>>.value(const <Tag>[]);
      _metaFuture = Future<WebRemoteMediaMeta>.error(missingMediaIdError);
      _imageFuture = Future<Uint8List>.error(missingMediaIdError);
      _pdfPageBytes = null;
      _pdfPageError = missingMediaIdError.toString();
      _pdfPageNo = 1;
      _pdfTotalPages = null;
      _loadingPdfPage = false;
      return;
    }
    _tagsFuture = widget.client.fetchItemTags(mediaId);
    _metaFuture = widget.client.fetchMediaMeta(mediaId);
    _imageFuture = widget.entry.isPdf
        ? Future<Uint8List>.value(Uint8List(0))
        : widget.client.fetchImageDownload(mediaId);
    _pdfPageBytes = null;
    _pdfPageError = null;
    _pdfPageNo = 1;
    _pdfTotalPages = null;
    _loadingPdfPage = false;
    if (widget.entry.isPdf) {
      _loadPdfPageCount();
      _loadPdfPage(1);
    }
  }

  Future<void> _loadPdfPageCount() async {

    final mediaId = widget.entry.mediaId;
    if (mediaId == null || mediaId.isEmpty) return;
    final stableId = widget.entry.stableId;
    try {
      final meta = await _metaFuture;
      final pageCountInfo = await widget.client.resolvePdfPageCountInfo(
        mediaId,
        pageCountHint: meta.pageCount,
      );
      if (!mounted || widget.entry.stableId != stableId) return;
      setState(() {
        _pdfTotalPages =
            pageCountInfo.isReliable || pageCountInfo.count > 1
                ? pageCountInfo.count
                : null;
        if (_pdfTotalPages != null) {
          _pdfPageNo = _pdfPageNo.clamp(1, _pdfTotalPages!);
        }
      });
    } catch (_) {
      // Keep the preview usable even when the server cannot report page counts.
    }
  }

  Future<void> _loadPdfPage(int pageNo) async {
    final mediaId = widget.entry.mediaId?.trim();
    if (mediaId == null || mediaId.isEmpty) {
      setState(() {
        _pdfPageError = 'Missing mediaId for ${widget.entry.displayName}';
        _loadingPdfPage = false;
      });
      return;
    }
    setState(() {
      _loadingPdfPage = true;
      _pdfPageError = null;
    });
    try {
      final bytes = await widget.client.fetchRenderedPdfPage(
        mediaId,
        pageNo,
        width: 1600,
      );
      if (!mounted) return;
      setState(() {
        _pdfPageNo = pageNo;
        _pdfPageBytes = bytes;
      });
    } catch (error, stackTrace) {
      debugPrint(
        '[WebMediaDetailView] Failed to load PDF page: mediaId=$mediaId page=$pageNo error=$error',
      );
      debugPrintStack(
        label: '[WebMediaDetailView] _loadPdfPage',
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _pdfPageError =
            'Failed to load page $pageNo for ${widget.entry.displayName}: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingPdfPage = false;
        });
      }
    }
  }

  String _formatDateTime(DateTime? value) {

    if (value == null) return '未取得';
    final local = value.toLocal();
    final two = (int number) => number.toString().padLeft(2, '0');
    return '${local.year}/${two(local.month)}/${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }

  String _formatBytes(int? bytes) {
    if (bytes == null) return '未取得';
    if (bytes < 1024) return '$bytes B';
    const units = <String>['KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var index = -1;
    while (value >= 1024 && index < units.length - 1) {
      value /= 1024;
      index += 1;
    }
    final digits = value >= 100 ? 0 : 1;
    return '${value.toStringAsFixed(digits)} ${units[index]}';
  }

  String _tagLabel(Tag tag) {
    switch (tag.category) {
      case TagCategory.artist:
        return 'artist:${tag.name}';
      case TagCategory.series:
        return 'series:${tag.name}';
      case TagCategory.mediaType:
        return 'type:${tag.name}';
      case TagCategory.character:
        return 'character:${tag.name}';
      case TagCategory.free:
        return '#${tag.name}';
    }
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 56,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white60, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: Text(value, style: const TextStyle(color: Colors.white70))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canOpenPreviousPdfPage = _pdfPageNo > 1;
    final canOpenNextPdfPage =
        !_loadingPdfPage &&
        (_pdfTotalPages == null || _pdfPageNo < _pdfTotalPages!);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: <Widget>[
            Text(
              _entryDisplayTitle(widget.entry),
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                Chip(
                  avatar: Icon(
                    widget.entry.isPdf
                        ? Icons.picture_as_pdf_outlined
                        : Icons.image_outlined,
                    size: 18,
                  ),
                  label: Text(widget.entry.isPdf ? 'PDF' : '画像'),
                ),
                Chip(
                  avatar: const Icon(Icons.folder_open, size: 18),
                  label: Text(widget.entry.folderRaw),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (widget.entry.isPdf)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      OutlinedButton.icon(
                        onPressed:
                            canOpenPreviousPdfPage
                                ? () => _loadPdfPage(_pdfPageNo - 1)
                                : null,
                        icon: const Icon(Icons.chevron_left),
                        label: const Text('前へ'),
                      ),
                      OutlinedButton.icon(
                        onPressed:
                            canOpenNextPdfPage
                                ? () => _loadPdfPage(_pdfPageNo + 1)
                                : null,
                        icon: const Icon(Icons.chevron_right),
                        label: const Text('次へ'),
                      ),
                      Text(
                        _pdfTotalPages == null
                            ? 'ページ $_pdfPageNo'
                            : 'ページ $_pdfPageNo / $_pdfTotalPages',
                        style: const TextStyle(color: Colors.white70),
                      ),
                      if (widget.onOpenPdfViewerPage != null)
                        FilledButton.icon(
                          onPressed: widget.onOpenPdfViewerPage,
                          icon: const Icon(Icons.open_in_full),
                          label: const Text('PDF 表示ページ'),
                        ),
                      FilledButton.icon(
                        onPressed:
                            widget.entry.mediaId == null
                                ? null
                                : () => widget.client.openPdfInNewTab(
                                  widget.entry.mediaId!,
                                ),
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('別タブで開く'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Container(
                    constraints: const BoxConstraints(minHeight: 320),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0E1117),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: Colors.white12),
                    ),
                    child:
                        _loadingPdfPage && _pdfPageBytes == null
                            ? const SizedBox(
                              height: 360,
                              child: Center(child: CircularProgressIndicator()),
                            )
                            : _pdfPageBytes != null
                            ? InteractiveViewer(
                              minScale: 0.7,
                              maxScale: 4,
                              child: Image.memory(
                                _pdfPageBytes!,
                                gaplessPlayback: true,
                                fit: BoxFit.contain,
                              ),
                            )
                            : Center(
                              child: Text(
                                _pdfPageError ?? 'PDF プレビューを読み込めませんでした',
                                style: TextStyle(color: Colors.red.shade200),
                              ),
                            ),
                  ),
                ],
              )
            else
              FutureBuilder<Uint8List>(
                future: _imageFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const SizedBox(
                      height: 360,
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (snapshot.hasError) {
                    return Container(
                      height: 240,
                      decoration: BoxDecoration(
                        color: const Color(0xFF0E1117),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: Colors.white12),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '画像を読み込めませんでした: ${snapshot.error}',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.red.shade200),
                      ),
                    );
                  }
                  final bytes = snapshot.data;
                  if (bytes == null || bytes.isEmpty) {
                    return const SizedBox(
                      height: 240,
                      child: Center(
                        child: Text('画像データがありません', style: TextStyle(color: Colors.white60)),
                      ),
                    );
                  }
                  return Container(
                    constraints: const BoxConstraints(minHeight: 320),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0E1117),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: InteractiveViewer(
                      minScale: 0.7,
                      maxScale: 5,
                      child: Image.memory(bytes, gaplessPlayback: true, fit: BoxFit.contain),
                    ),
                  );
                },
              ),
            const SizedBox(height: 16),
            FutureBuilder<WebRemoteMediaMeta>(
              future: _metaFuture,
              builder: (context, snapshot) {
                final meta = snapshot.data;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _detailRow('種別', widget.entry.isPdf ? 'PDF' : '画像'),
                    _detailRow('更新', _formatDateTime(meta?.modifiedAt ?? widget.entry.modifiedAt)),
                    _detailRow('サイズ', _formatBytes(meta?.sizeBytes ?? widget.entry.sizeBytes)),
                    _detailRow('MIME', meta?.mimeType ?? '未取得'),
                  ],
                );
              },
            ),
            const SizedBox(height: 16),
            const Text('タグ', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            FutureBuilder<List<Tag>>(
              future: _tagsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Text(
                    'タグを読み込めませんでした: ${snapshot.error}',
                    style: TextStyle(color: Colors.red.shade200),
                  );
                }
                final tags = snapshot.data ?? const <Tag>[];
                if (tags.isEmpty) {
                  return const Text('タグはまだ付いていません。', style: TextStyle(color: Colors.white60));
                }
                return Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children:
                      tags
                          .map(
                            (tag) => ActionChip(
                              label: Text(_tagLabel(tag)),
                              onPressed: () => widget.onApplyTagQuery(
                                WebSearchParser.formatTagQuery(tag),
                              ),
                            ),
                          )
                          .toList(growable: false),
                );
              },
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF121A26),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white12),
              ),
              child: const Text(
                'Web 版では PDF の簡易プレビューに加えて、同じタブ内の PDF 表示ページと別タブ表示を使い分けられます。',
                style: TextStyle(color: Colors.white70),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class WebPdfViewerPage extends StatefulWidget {
  final WebRemoteApiClient client;
  final WebRemoteEntry entry;
  final Future<void> Function()? onOpenDetail;

  const WebPdfViewerPage({
    super.key,
    required this.client,
    required this.entry,
    this.onOpenDetail,
  });

  @override
  State<WebPdfViewerPage> createState() => _WebPdfViewerPageState();
}

class _WebPdfViewerPageState extends State<WebPdfViewerPage> {
  static const String _twoPagePrefsKey = 'prefs.readerTwoPage';

  Object? _loadError;
  bool _loading = false;
  int _page = 1;
  int _totalPages = 1;
  bool _pageCountReliable = false;
  bool _twoPage = false;
  final Map<int, Future<Uint8List>> _pageFutureCache =
      <int, Future<Uint8List>>{};
  Future<Uint8List>? _leftFuture;
  Future<Uint8List>? _rightFuture;

  @override
  void initState() {
    super.initState();
    _loadViewer();
  }

  @override
  void didUpdateWidget(covariant WebPdfViewerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.stableId != widget.entry.stableId) {
      _pageFutureCache.clear();
      _page = 1;
      _totalPages = 1;
      _pageCountReliable = false;
      _leftFuture = null;
      _rightFuture = null;
      _loadViewer();
    }
  }

  Future<void> _loadViewer() async {
    final mediaId = widget.entry.mediaId;
    if (mediaId == null || mediaId.isEmpty) {
      setState(() {
        _loadError = StateError('PDF を表示するための mediaId がありません');
        _loading = false;
        _leftFuture = null;
        _rightFuture = null;
      });
      return;
    }

    setState(() {
      _loading = true;
      _loadError = null;
      _pageFutureCache.clear();
      _page = 1;
      _totalPages = 1;
      _pageCountReliable = false;
      _leftFuture = null;
      _rightFuture = null;
      _syncPageFutures();
    });

    try {
      final twoPageFuture = SharedPreferences.getInstance()
          .then((prefs) => prefs.getBool(_twoPagePrefsKey))
          .catchError((Object error, StackTrace stackTrace) {
            debugPrint('[WebPdfViewerPage] Failed to load reader prefs: $error');
            debugPrintStack(
              label: '[WebPdfViewerPage] _loadViewer',
              stackTrace: stackTrace,
            );
            return null;
          });
      final meta = await widget.client.fetchMediaMeta(mediaId);
      final pageCountInfo = await widget.client.resolvePdfPageCountInfo(
        mediaId,
        pageCountHint: meta.pageCount,
      );
      final twoPage = await twoPageFuture;
      if (!mounted) return;
      setState(() {
        _twoPage = twoPage ?? _twoPage;
        _totalPages = pageCountInfo.count.clamp(1, 1 << 30);
        _pageCountReliable = pageCountInfo.isReliable;
        _page = _page.clamp(1, _totalPages);
        _syncPageFutures();
      });
    } catch (error) {
      if (!mounted) return;
      if (_leftFuture == null) {
        setState(() {
          _loadError = error;
          _leftFuture = null;
          _rightFuture = null;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<Uint8List> _loadPageBytes(int pageNo) {
    final mediaId = widget.entry.mediaId;
    if (mediaId == null || mediaId.isEmpty) {
      return Future<Uint8List>.error(
        StateError('PDF を表示するための mediaId がありません'),
      );
    }
    return _pageFutureCache.putIfAbsent(pageNo, () {
      return widget.client.fetchRenderedPdfPage(mediaId, pageNo, width: 1600);
    });
  }

  void _syncPageFutures() {
    _leftFuture = _loadPageBytes(_page);
    if (_twoPage) {
      final nextPage = _page + 1;
      _rightFuture = nextPage <= _totalPages ? _loadPageBytes(nextPage) : null;
      return;
    }
    _rightFuture = null;
  }

  void _setCurrentPage(int page) {
    setState(() {
      _page = page.clamp(1, _totalPages);
      _syncPageFutures();
    });
  }

  Future<bool> _tryOpenPage(int page) async {
    if (page < 1) {
      return false;
    }
    if (page <= _totalPages) {
      _setCurrentPage(page);
      return true;
    }
    if (_pageCountReliable || _loading) {
      return false;
    }
    final mediaId = widget.entry.mediaId;
    if (mediaId == null || mediaId.isEmpty) {
      return false;
    }

    setState(() {
      _loading = true;
    });
    try {
      final bytes = await widget.client.fetchPdfPage(mediaId, page, width: 1600);
      if (!mounted) {
        return false;
      }
      setState(() {
        _pageFutureCache[page] = Future<Uint8List>.value(bytes);
        _totalPages = page;
        _page = page;
        _syncPageFutures();
      });
      return true;
    } catch (_) {
      if (!mounted) {
        return false;
      }
      setState(() {
        _pageCountReliable = true;
        _totalPages = page > 1 ? page - 1 : 1;
        _page = _page.clamp(1, _totalPages);
        _pageFutureCache.remove(page);
        _syncPageFutures();
      });
      return false;
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  void _next() {
    final step = _twoPage && _rightFuture == null ? 1 : (_twoPage ? 2 : 1);
    final next = _page + step;
    if (next <= _totalPages) {
      _setCurrentPage(next);
      return;
    }
    if (!_pageCountReliable) {
      unawaited(_tryOpenPage(next));
    }
  }

  void _prev() {
    final step = _twoPage && _rightFuture == null ? 1 : (_twoPage ? 2 : 1);
    final prev = _page - step;
    if (prev >= 1) {
      _setCurrentPage(prev);
    }
  }

  Future<void> _toggleTwoPage() async {
    final nextValue = !_twoPage;
    setState(() {
      _twoPage = nextValue;
      _syncPageFutures();
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_twoPagePrefsKey, nextValue);
    } catch (error, stackTrace) {
      debugPrint('[WebPdfViewerPage] Failed to save reader prefs: $error');
      debugPrintStack(
        label: '[WebPdfViewerPage] _toggleTwoPage',
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _handleOpenDetail([BuildContext? context]) async {
    if (context != null) {
      final navigator = Navigator.of(context);
      if (navigator.canPop()) {
        navigator.pop();
        return;
      }
    }
    final onOpenDetail = widget.onOpenDetail;
    if (onOpenDetail == null) return;
    await onOpenDetail();
  }

  Widget _buildLoadError(String message, {required VoidCallback onRetry}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.cloud_off_outlined,
              color: Colors.white70,
              size: 34,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('再試行'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPageImage(
    Future<Uint8List>? future, {
    required Alignment align,
    required bool isSpread,
    required int pageNumber,
  }) {
    if (future == null) {
      return const SizedBox.shrink();
    }

    return FutureBuilder<Uint8List>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _buildLoadError(
            'ページ画像の読み込みに失敗しました。\n${snapshot.error}',
            onRetry: () {
              setState(() {
                _pageFutureCache.remove(pageNumber);
                _syncPageFutures();
              });
            },
          );
        }

        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final image = Image.memory(
          snapshot.data!,
          fit: isSpread ? BoxFit.fitHeight : BoxFit.fitWidth,
          alignment: align,
          gaplessPlayback: true,
          filterQuality: FilterQuality.high,
        );

        return InteractiveViewer(
          minScale: 0.5,
          maxScale: 6,
          alignment: align,
          child: Align(
            alignment: align,
            child: DecoratedBox(
              decoration: const BoxDecoration(color: Colors.white),
              child: image,
            ),
          ),
        );
      },
    );
  }

  Widget _buildViewerBody() {
    if (_loading && _leftFuture == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null) {
      return _buildLoadError(
        'PDF 表示ページを読み込めませんでした。\n$_loadError',
        onRetry: _loadViewer,
      );
    }
    return Stack(
      children: <Widget>[
        Center(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final gap = constraints.maxWidth < 720 ? 6.0 : 12.0;
              final isSpread = _twoPage;
              final pageWidth = isSpread
                  ? (constraints.maxWidth - gap) / 2.0
                  : constraints.maxWidth;

              return Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  SizedBox(
                    width: pageWidth,
                    child: _buildPageImage(
                      _leftFuture,
                      align: isSpread
                          ? Alignment.centerRight
                          : Alignment.center,
                      isSpread: isSpread,
                      pageNumber: _page,
                    ),
                  ),
                  if (isSpread) ...<Widget>[
                    SizedBox(width: gap),
                    SizedBox(
                      width: pageWidth,
                      child: _buildPageImage(
                        _rightFuture,
                        align: Alignment.centerLeft,
                        isSpread: isSpread,
                        pageNumber: _page + 1,
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTapUp: (details) {
                  final dx = details.localPosition.dx;
                  final width = constraints.maxWidth;
                  final leftEdge = width * 0.35;
                  final rightEdge = width * 0.65;
                  if (dx < leftEdge) {
                    _prev();
                  } else if (dx > rightEdge) {
                    _next();
                  }
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildToolbar() {
    final canPrev = _page > 1;
    final canNext =
        !_loading &&
        (!_pageCountReliable || _page + (_twoPage ? 2 : 1) <= _totalPages);
    final totalPagesText = _pageCountReliable ? '$_totalPages' : '$_totalPages+';
    final pageText = '$_page/$totalPagesText';

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        OutlinedButton.icon(
          onPressed: canPrev ? _prev : null,
          icon: const Icon(Icons.chevron_left),
          label: const Text('前'),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white12,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Colors.white10),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Text(pageText),
          ),
        ),
        OutlinedButton.icon(
          onPressed: canNext ? _next : null,
          icon: const Icon(Icons.chevron_right),
          label: const Text('次'),
        ),
        TextButton.icon(
          onPressed: _toggleTwoPage,
          icon: const Icon(Icons.swap_horiz),
          label: Text(_twoPage ? '見開き ON' : '見開き OFF'),
        ),
      ],
    );
  }

  Widget _buildCompactViewerHeader(BuildContext context) {
    final canPrev = _page > 1;
    final canNext =
        !_loading &&
        (!_pageCountReliable || _page + (_twoPage ? 2 : 1) <= _totalPages);
    final totalPagesText = _pageCountReliable ? '$_totalPages' : '$_totalPages+';
    final pageText = '$_page / $totalPagesText';
    final canReturn = Navigator.of(context).canPop() || widget.onOpenDetail != null;

    return Material(
      color: Colors.black,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 56,
          child: Row(
            children: <Widget>[
              IconButton(
                onPressed: canReturn ? () => _handleOpenDetail(context) : null,
                tooltip: '詳細へ戻る',
                icon: const Icon(Icons.arrow_back_ios_new_rounded),
              ),
              IconButton(
                onPressed: canPrev ? _prev : null,
                tooltip: '前のページ',
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              IconButton(
                onPressed: canNext ? _next : null,
                tooltip: '次のページ',
                icon: const Icon(Icons.chevron_right_rounded),
              ),
              IconButton(
                onPressed: _toggleTwoPage,
                tooltip: _twoPage ? '見開きをオフ' : '見開きをオン',
                icon: Icon(
                  _twoPage
                      ? Icons.chrome_reader_mode_rounded
                      : Icons.menu_book_rounded,
                ),
              ),
              const Spacer(),
              Container(
                margin: const EdgeInsets.only(right: 12),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.white10),
                ),
                child: Text(
                  pageText,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.entry.isPdf) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Column(
          children: <Widget>[
            _buildCompactViewerHeader(context),
            Expanded(
              child: ColoredBox(
                color: const Color(0xFF0E1117),
                child: SafeArea(
                  top: false,
                  child: _buildViewerBody(),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: <Widget>[
            if (widget.onOpenDetail != null) ...[
              TextButton.icon(
                onPressed: _handleOpenDetail,
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                icon: const Icon(Icons.description_outlined),
                label: const Text('PDF詳細'),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Text(
                _entryDisplayTitle(widget.entry),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: <Widget>[
          IconButton(
            onPressed: widget.entry.mediaId == null
                ? null
                : () => widget.client.openPdfInNewTab(widget.entry.mediaId!),
            tooltip: '新しいタブで開く',
            icon: const Icon(Icons.open_in_new),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  const Chip(
                    avatar: Icon(Icons.picture_as_pdf_outlined, size: 18),
                    label: Text('PDF'),
                  ),
                  Chip(
                    avatar: const Icon(Icons.folder_open, size: 18),
                    label: Text(widget.entry.folderRaw),
                  ),
                  Chip(
                    avatar: const Icon(Icons.menu_book_outlined, size: 18),
                    label: Text('$_totalPages ページ'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _buildToolbar(),
              const SizedBox(height: 12),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xFF0E1117),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: _buildViewerBody(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WebUrlImportRequest {
  final String sourceUrl;
  final UrlImportOptions options;
  final ImportMetadata importMetadata;

  const _WebUrlImportRequest({
    required this.sourceUrl,
    required this.options,
    required this.importMetadata,
  });

  bool get hasAnySource => options.hasAnySource(sourceUrl);
}

class _WebUrlImportDialog extends StatefulWidget {
  final String folderName;

  const _WebUrlImportDialog({
    required this.folderName,
  });

  static Future<_WebUrlImportRequest?> show(
    BuildContext context, {
    required String folderName,
  }) {
    return showDialog<_WebUrlImportRequest>(
      context: context,
      builder: (_) => _WebUrlImportDialog(folderName: folderName),
    );
  }

  @override
  State<_WebUrlImportDialog> createState() => _WebUrlImportDialogState();
}

class _WebUrlImportDialogState extends State<_WebUrlImportDialog> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _favoriteUsersController =
      TextEditingController();
  final TextEditingController _parallelDownloadsController =
      TextEditingController(text: '6');

  bool _siteKemono = true;
  bool _siteCoomer = false;
  bool _favoritePosts = false;
  bool _includeInlineImages = false;
  bool _includePostContent = false;
  bool _includeComments = false;
  bool _saveJson = false;
  bool _overwriteExistingFiles = false;
  bool _verbose = false;
  bool _convertHitomiToPdf = true;
  bool _organizeAfterImport = false;
  UrlImportMediaType _mediaType = UrlImportMediaType.all;
  UrlImportCookieMode _cookieMode = UrlImportCookieMode.auto;
  String? _validationMessage;

  @override
  void dispose() {
    _urlController.dispose();
    _favoriteUsersController.dispose();
    _parallelDownloadsController.dispose();
    super.dispose();
  }

  UrlImportOptions get _options => UrlImportOptions(
    cookieMode: _cookieMode,
    favoriteSites: <String>[
      if (_siteKemono) 'kemono',
      if (_siteCoomer) 'coomer',
    ],
    favoritePosts: _favoritePosts,
    favoriteUserServices: _splitCommaSeparated(_favoriteUsersController.text),
    mediaType: _mediaType,
    parallelDownloads:
        int.tryParse(_parallelDownloadsController.text.trim()) ?? 6,
    includeInlineImages: _includeInlineImages,
    includePostContent: _includePostContent,
    includeComments: _includeComments,
    saveJson: _saveJson,
    overwriteExistingFiles: _overwriteExistingFiles,
    verbose: _verbose,
    convertHitomiToPdf: _convertHitomiToPdf,
  );

  ImportMetadata get _importMetadata => ImportMetadata(
    organizeAfterImport: _organizeAfterImport,
  );

  List<String> _splitCommaSeparated(String raw) {
    final values = <String>[];
    final seen = <String>{};
    for (final chunk in raw.split(',')) {
      final trimmed = chunk.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      final normalized = trimmed.toLowerCase();
      if (seen.add(normalized)) {
        values.add(trimmed);
      }
    }
    return values;
  }

  List<String> _collectSourceUrls(String raw) {
    return const UrlImportOptions().collectSourceUrls(raw);
  }

  String _normalizeSourceUrlText(String raw) {
    return _collectSourceUrls(raw).join(', ');
  }

  void _replaceSourceUrlText(String raw) {
    final normalized = _normalizeSourceUrlText(raw);
    _urlController.value = TextEditingValue(
      text: normalized,
      selection: TextSelection.collapsed(offset: normalized.length),
    );
  }

  Future<void> _pasteSourceUrls() async {
    try {
      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      final pastedText = clipboardData?.text ?? '';
      final incomingUrls = _collectSourceUrls(pastedText);
      if (!mounted) {
        return;
      }
      if (incomingUrls.isEmpty) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('No URL found in clipboard')),
        );
        return;
      }
      final mergedUrls = <String>[
        ..._collectSourceUrls(_urlController.text),
        ...incomingUrls,
      ];
      setState(() {
        _validationMessage = null;
      });
      _replaceSourceUrlText(mergedUrls.join(', '));
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Clipboard read failed')),
      );
    }
  }

  String _cookieModeLabel(UrlImportCookieMode mode) {
    switch (mode) {
      case UrlImportCookieMode.auto:
        return '自動';
      case UrlImportCookieMode.none:
        return '使わない';
      case UrlImportCookieMode.projectKemono:
        return 'Host Kemono Cookie';
      case UrlImportCookieMode.projectCoomer:
        return 'Host Coomer Cookie';
      case UrlImportCookieMode.projectCombined:
        return 'Host Combined Cookie';
      case UrlImportCookieMode.customFile:
        return 'カスタム';
    }
  }

  bool _validate({required bool showMessage}) {
    final sourceUrl = _normalizeSourceUrlText(_urlController.text);
    final options = _options;
    String? message;

    if (!options.hasAnySource(sourceUrl)) {
      message = 'URL または favorites 条件を入力してください。';
    } else if (options.hasFavoriteTargets && !options.hasCookieSelection) {
      message = 'favorites を使う場合は Cookie を選択してください。';
    } else if (options.hasFavoriteTargets &&
        options.normalizedFavoriteSites.isEmpty) {
      message = 'favorites を使う場合は対象サイトを選択してください。';
    }

    if (showMessage) {
      setState(() {
        _validationMessage = message;
      });
    }
    return message == null;
  }

  void _submit() {
    if (!_validate(showMessage: true)) {
      return;
    }

    final normalizedSourceUrl = _normalizeSourceUrlText(_urlController.text);
    _replaceSourceUrlText(normalizedSourceUrl);

    Navigator.of(context).pop(
      _WebUrlImportRequest(
        sourceUrl: normalizedSourceUrl,
        options: _options,
        importMetadata: _importMetadata,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final detectedUrlCount = _collectSourceUrls(_urlController.text).length;
    return AlertDialog(
      title: const Text('ホストへ URL 取り込み'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 760),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('保存先: ${widget.folderName}'),
              const SizedBox(height: 8),
              const Text(
                'Hitomi / Kemono / Coomer の URL や favorites 条件をホストへ送って実行します。',
                style: TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _urlController,
                autofocus: true,
                minLines: 4,
                maxLines: 8,
                onChanged: (_) => setState(() => _validationMessage = null),
                decoration: const InputDecoration(
                  labelText: 'Source URLs',
                  alignLabelWithHint: true,
                  hintText:
                      'https://hitomi.la/...\nhttps://kemono.su/...',
                  helperText:
                      'Paste multiple URLs with spaces, new lines, or commas. The dialog will normalize them into comma-separated URLs.',
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  OutlinedButton.icon(
                    onPressed: _pasteSourceUrls,
                    icon: const Icon(Icons.content_paste_go_outlined),
                    label: const Text('Paste'),
                  ),
                  if (detectedUrlCount > 0)
                    Chip(
                      avatar: const Icon(Icons.link, size: 18),
                      label: Text('$detectedUrlCount URLs'),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              Text(
                'Cookie と favorites',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<UrlImportCookieMode>(
                value: _cookieMode,
                decoration: const InputDecoration(labelText: 'Cookie の使い方'),
                items: const <UrlImportCookieMode>[
                  UrlImportCookieMode.auto,
                  UrlImportCookieMode.none,
                  UrlImportCookieMode.projectKemono,
                  UrlImportCookieMode.projectCoomer,
                  UrlImportCookieMode.projectCombined,
                ]
                    .map(
                      (mode) => DropdownMenuItem(
                        value: mode,
                        child: Text(_cookieModeLabel(mode)),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (value) {
                  if (value == null) {
                    return;
                  }
                  setState(() {
                    _cookieMode = value;
                    _validationMessage = null;
                  });
                },
              ),
              const SizedBox(height: 8),
              const Text(
                'Web からはホスト側の project cookie を使います。ブラウザ端末のローカル cookie.txt は指定できません。',
                style: TextStyle(color: Colors.white60),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  FilterChip(
                    label: const Text('Kemono'),
                    selected: _siteKemono,
                    onSelected: (selected) {
                      setState(() {
                        _siteKemono = selected;
                        _validationMessage = null;
                      });
                    },
                  ),
                  FilterChip(
                    label: const Text('Coomer'),
                    selected: _siteCoomer,
                    onSelected: (selected) {
                      setState(() {
                        _siteCoomer = selected;
                        _validationMessage = null;
                      });
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                value: _favoritePosts,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('favorite posts を取り込む'),
                onChanged: (value) {
                  setState(() {
                    _favoritePosts = value ?? false;
                    _validationMessage = null;
                  });
                },
              ),
              TextField(
                controller: _favoriteUsersController,
                onChanged: (_) => setState(() => _validationMessage = null),
                decoration: const InputDecoration(
                  labelText: 'favorite users サービス',
                  hintText: 'all / patreon,fanbox / onlyfans',
                  helperText: '空欄なら favorite users は使いません',
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'ダウンロード設定',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<UrlImportMediaType>(
                value: _mediaType,
                decoration: const InputDecoration(labelText: 'メディア種別'),
                items: const <DropdownMenuItem<UrlImportMediaType>>[
                  DropdownMenuItem(
                    value: UrlImportMediaType.all,
                    child: Text('すべて'),
                  ),
                  DropdownMenuItem(
                    value: UrlImportMediaType.images,
                    child: Text('画像のみ'),
                  ),
                  DropdownMenuItem(
                    value: UrlImportMediaType.videos,
                    child: Text('動画のみ'),
                  ),
                  DropdownMenuItem(
                    value: UrlImportMediaType.imagesVideos,
                    child: Text('画像と動画'),
                  ),
                ],
                onChanged: (value) {
                  if (value == null) {
                    return;
                  }
                  setState(() {
                    _mediaType = value;
                  });
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _parallelDownloadsController,
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() => _validationMessage = null),
                decoration: const InputDecoration(
                  labelText: '並列ダウンロード数',
                  helperText: '既定は 6 です',
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  FilterChip(
                    label: const Text('Hitomi を PDF 化'),
                    selected: _convertHitomiToPdf,
                    onSelected: (selected) => setState(() {
                      _convertHitomiToPdf = selected;
                    }),
                  ),
                  FilterChip(
                    label: const Text('取り込み後に整理'),
                    selected: _organizeAfterImport,
                    onSelected: (selected) => setState(() {
                      _organizeAfterImport = selected;
                    }),
                  ),
                  FilterChip(
                    label: const Text('inline 画像'),
                    selected: _includeInlineImages,
                    onSelected: (selected) => setState(() {
                      _includeInlineImages = selected;
                    }),
                  ),
                  FilterChip(
                    label: const Text('本文保存'),
                    selected: _includePostContent,
                    onSelected: (selected) => setState(() {
                      _includePostContent = selected;
                    }),
                  ),
                  FilterChip(
                    label: const Text('コメント保存'),
                    selected: _includeComments,
                    onSelected: (selected) => setState(() {
                      _includeComments = selected;
                    }),
                  ),
                  FilterChip(
                    label: const Text('JSON 保存'),
                    selected: _saveJson,
                    onSelected: (selected) => setState(() {
                      _saveJson = selected;
                    }),
                  ),
                  FilterChip(
                    label: const Text('上書き'),
                    selected: _overwriteExistingFiles,
                    onSelected: (selected) => setState(() {
                      _overwriteExistingFiles = selected;
                    }),
                  ),
                  FilterChip(
                    label: const Text('詳細ログ'),
                    selected: _verbose,
                    onSelected: (selected) => setState(() {
                      _verbose = selected;
                    }),
                  ),
                ],
              ),
              if (_validationMessage != null) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  _validationMessage!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('キャンセル'),
        ),
        FilledButton.icon(
          onPressed: _validate(showMessage: false) ? _submit : null,
          icon: const Icon(Icons.download_outlined),
          label: const Text('ホストで実行'),
        ),
      ],
    );
  }
}

class _RemoteThumbnail extends StatefulWidget {
  final WebRemoteApiClient? client;
  final WebRemoteEntry entry;
  final double width;
  final double height;
  final double borderRadius;
  final Color backgroundColor;

  const _RemoteThumbnail({
    super.key,
    required this.client,
    required this.entry,
    this.width = 132,
    this.height = 184,
    this.borderRadius = 14,
    this.backgroundColor = const Color(0xFF0F141C),
  });

  @override
  State<_RemoteThumbnail> createState() => _RemoteThumbnailState();
}

class _RemoteThumbnailState extends State<_RemoteThumbnail> {
  Future<Uint8List>? _future;

  @override
  void initState() {
    super.initState();
    _refreshFuture();
  }

  @override
  void didUpdateWidget(covariant _RemoteThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.stableId != widget.entry.stableId ||
        oldWidget.client != widget.client) {
      _refreshFuture();
    }
  }

  void _refreshFuture() {
    final client = widget.client;
    if (client == null || widget.entry.isFolder || widget.entry.mediaId == null) {
      _future = null;
      return;
    }
    _future = client.fetchThumbnail(
      widget.entry.mediaId!,
      width: (widget.width * 1.8).round(),
      height: (widget.height * 1.8).round(),
      page: widget.entry.isPdf ? 1 : null,
    );
  }

  Widget _shell(Widget child) {
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: widget.backgroundColor,
        borderRadius: BorderRadius.circular(widget.borderRadius),
        border: Border.all(color: Colors.white12),
      ),
      alignment: Alignment.center,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.entry.isFolder) {
      return _shell(
        const Icon(Icons.folder_copy_outlined, size: 48, color: Colors.white70),
      );
    }

    if (_future == null) {
      return _shell(
        const Icon(Icons.broken_image_outlined, size: 40, color: Colors.white54),
      );
    }

    return FutureBuilder<Uint8List>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _shell(
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        if (snapshot.hasError) {
          return _shell(
            Icon(
              widget.entry.isPdf ? Icons.picture_as_pdf : Icons.image_not_supported_outlined,
              size: 40,
              color: Colors.white54,
            ),
          );
        }
        final bytes = snapshot.data;
        if (bytes == null || bytes.isEmpty) {
          return _shell(
            const Icon(Icons.image_not_supported_outlined, size: 40, color: Colors.white54),
          );
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          child: Image.memory(
            bytes,
            width: widget.width,
            height: widget.height,
            fit: BoxFit.cover,
            gaplessPlayback: true,
          ),
        );
      },
    );
  }
}

extension _IterableFirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
