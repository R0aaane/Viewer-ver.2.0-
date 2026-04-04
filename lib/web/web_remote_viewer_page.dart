// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/metadata_settings.dart';
import '../models/tag.dart';
import '../repository/mediaRepository.dart';
import '../services/app_settings_service.dart';
import 'web_remote_api_client.dart';

enum _WebMediaFilter {
  all('すべて'),
  pdf('PDF'),
  image('画像');

  final String label;
  const _WebMediaFilter(this.label);
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
  late MetadataSettings _settings;
  late final TextEditingController _apiController;
  late final TextEditingController _tokenController;
  late final TextEditingController _searchController;

  WebRemoteApiClient? _client;
  List<WebRemoteFolder> _folders = const <WebRemoteFolder>[];
  List<WebRemoteEntry> _entries = const <WebRemoteEntry>[];
  WebRemoteEntry? _selectedEntry;
  String? _selectedFolderRaw;
  bool _isConnecting = false;
  bool _isLoading = false;
  bool _actionBusy = false;
  String? _statusMessage;
  String? _errorMessage;
  _WebMediaFilter _filter = _WebMediaFilter.all;

  @override
  void initState() {
    super.initState();
    _settings = _resolveInitialSettings(widget.initialSettings);
    _apiController = TextEditingController(text: _settings.clientApiBaseUrl);
    _tokenController = TextEditingController(text: _settings.authToken ?? '');
    _searchController = TextEditingController();
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
        _selectedEntry = null;
        _selectedFolderRaw = null;
        _isConnecting = false;
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
        _selectedEntry = null;
        _selectedFolderRaw = null;
        _isConnecting = false;
        _errorMessage = compatibilityError;
      });
      return;
    }

    final client = WebRemoteApiClient(
      baseUrl: apiBaseUrl,
      authToken: authToken.isEmpty ? null : authToken,
    );

    try {
      await client.checkHealth();
      final folders = await client.listFolders();
      final selectedFolder = _selectedFolderRaw ?? (folders.isNotEmpty ? folders.first.raw : null);
      if (!mounted) return;
      setState(() {
        _client = client;
        _folders = folders;
        _selectedFolderRaw = selectedFolder;
        _statusMessage = '接続済み: ${_settings.clientApiBaseUrl}';
      });
      if (selectedFolder != null) {
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
        _selectedEntry = null;
        _errorMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isConnecting = false;
        });
      }
    }
  }

  Future<void> _loadEntries() async {
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
          rawQuery.isEmpty
              ? await client.listFolderChildren(folderRaw, limit: 300)
              : await client.search(
                WebSearchParser.parse(rawQuery),
                folderRaw: folderRaw,
                limit: 300,
              );

      fetched.sort((left, right) {
        if (left.isFolder != right.isFolder) {
          return left.isFolder ? -1 : 1;
        }
        final leftModified = left.modifiedAt?.millisecondsSinceEpoch ?? 0;
        final rightModified = right.modifiedAt?.millisecondsSinceEpoch ?? 0;
        final modifiedCompare = rightModified.compareTo(leftModified);
        if (modifiedCompare != 0) {
          return modifiedCompare;
        }
        return left.displayName.toLowerCase().compareTo(right.displayName.toLowerCase());
      });

      final filtered = _applyFilter(fetched);
      WebRemoteEntry? nextSelected = _selectedEntry;
      if (nextSelected != null) {
        final stableId = nextSelected.stableId;
        nextSelected = filtered
            .where((entry) => entry.stableId == stableId)
            .cast<WebRemoteEntry?>()
            .firstOrNull;
      }
      nextSelected ??=
          filtered.where((entry) => !entry.isFolder).cast<WebRemoteEntry?>().firstOrNull;

      if (!mounted) return;
      setState(() {
        _entries = filtered;
        _selectedEntry = nextSelected;
        _statusMessage =
            rawQuery.isEmpty ? 'フォルダを読み込みました' : '検索結果 ${filtered.length} 件';
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

  List<WebRemoteEntry> _applyFilter(List<WebRemoteEntry> items) {
    switch (_filter) {
      case _WebMediaFilter.all:
        return items;
      case _WebMediaFilter.pdf:
        return items.where((entry) => entry.isFolder || entry.isPdf).toList();
      case _WebMediaFilter.image:
        return items.where((entry) => entry.isFolder || entry.isImage).toList();
    }
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

  String? _parentFolder(String raw) {
    final context = _pathContext(raw);
    final parent = context.dirname(raw);
    if (parent == '.' || parent == raw) {
      return null;
    }
    return parent;
  }

  Future<void> _selectFolder(String folderRaw) async {
    setState(() {
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
              appBar: AppBar(title: Text(entry.displayName)),
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

        return Scaffold(
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
                    padding: const EdgeInsets.all(16),
                    child:
                        splitView
                            ? Row(
                              children: <Widget>[
                                Expanded(flex: 6, child: _buildBrowserPane(splitView)),
                                const SizedBox(width: 16),
                                SizedBox(width: 420, child: _buildDetailPane()),
                              ],
                            )
                            : _buildBrowserPane(splitView),
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
          if (_folders.isEmpty)
            const Text('接続後に閲覧可能なフォルダを表示します。', style: TextStyle(color: Colors.white60)),
          for (final folder in _folders)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                selected: _selectedFolderRaw == folder.raw,
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

  Widget _buildBrowserPane(bool splitView) {
    final parentFolder = _selectedFolderRaw == null ? null : _parentFolder(_selectedFolderRaw!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _BrowserHeader(
          folderName: _selectedFolderRaw == null ? null : _folderName(_selectedFolderRaw!),
          itemCount: _entries.length,
          searchController: _searchController,
          isLoading: _isLoading,
          actionsBusy: _actionBusy,
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
        ),
        const SizedBox(height: 16),
        Expanded(child: _buildList(splitView)),
      ],
    );
  }

  Widget _buildList(bool splitView) {
    return Card(
      child: RefreshIndicator(
        onRefresh: _loadEntries,
        child:
            _entries.isEmpty && !_isLoading
                ? ListView(
                  padding: const EdgeInsets.all(24),
                  children: const <Widget>[
                    Icon(Icons.travel_explore, size: 52, color: Colors.white30),
                    SizedBox(height: 12),
                    Text(
                      'この条件では表示できる項目がありません。',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white70),
                    ),
                  ],
                )
                : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _entries.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final entry = _entries[index];
                    final selected = _selectedEntry?.stableId == entry.stableId;
                    return _EntryCard(
                      key: ValueKey<String>(entry.stableId),
                      client: _client,
                      entry: entry,
                      selected: selected,
                      onTap: () => _handleEntryTap(entry, splitView: splitView),
                      folderName: _folderName,
                    );
                  },
                ),
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
    if (value == null) return 'N/A';
    final local = value.toLocal();
    final two = (int number) => number.toString().padLeft(2, '0');
    return '${local.year}/${two(local.month)}/${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
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

String _formatBrowseDateTime(DateTime? value) {
  if (value == null) {
    return 'N/A';
  }
  final local = value.toLocal();
  final two = (int number) => number.toString().padLeft(2, '0');
  return '${local.year}/${two(local.month)}/${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

String _formatBrowseBytes(int? bytes) {
  if (bytes == null) {
    return 'N/A';
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

class _EntryCard extends StatelessWidget {
  final WebRemoteApiClient? client;
  final WebRemoteEntry entry;
  final bool selected;
  final VoidCallback onTap;
  final String Function(String raw) folderName;

  const _EntryCard({
    super.key,
    required this.client,
    required this.entry,
    required this.selected,
    required this.onTap,
    required this.folderName,
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
          entry.displayName,
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
                entry.isFolder ? 'Folder' : entry.isPdf ? 'PDF' : 'Image',
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
      return 'N/A';
    }
    final local = value.toLocal();
    final two = (int number) => number.toString().padLeft(2, '0');
    return '${local.year}/${two(local.month)}/${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  String _formatBytes(int? bytes) {
    if (bytes == null) {
      return 'N/A';
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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: selected ? accent : accent.withOpacity(0.84),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        entry.displayName,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Color(0xFF362324),
          fontSize: 28,
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
    final width = compact ? 206.0 : 250.0;
    final height = compact ? 230.0 : 280.0;
    final thumbWidth = compact ? 134.0 : 164.0;
    final thumbHeight = compact ? 188.0 : 228.0;

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
            left: 18,
            top: 18,
            angle: -0.06,
            color: const Color(0xFF2A2734),
          ),
          panel(
            left: 48,
            top: 12,
            angle: 0.03,
            color: const Color(0xFF242230),
          ),
          panel(
            left: 78,
            top: 6,
            angle: -0.02,
            color: const Color(0xFF1D1B29),
          ),
          Positioned(
            left: 84,
            top: 38,
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

class _EntryMetadataSummary extends StatefulWidget {
  final WebRemoteApiClient? client;
  final WebRemoteEntry entry;
  final Color accent;
  final String Function(String raw) folderName;

  const _EntryMetadataSummary({
    required this.client,
    required this.entry,
    required this.accent,
    required this.folderName,
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

  Widget _tag(String label) {
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
            'Loading metadata...',
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
                  ? 'Folder'
                  : widget.entry.isPdf
                  ? 'PDF'
                  : 'Image',
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
            'Failed to load metadata',
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
              widget.entry.isPdf ? 'PDF' : 'Image',
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
          _row('Location', data.location, maxLines: 2),
          _row('Updated', data.updatedAt),
          const SizedBox(height: 8),
          const Text(
            'Tap to open this folder',
            style: TextStyle(
              color: Color(0xFF6E5959),
              fontWeight: FontWeight.w600,
            ),
          ),
        ] else ...<Widget>[
          _row('Creator', data.artist),
          _row('Series', data.series),
          _row('Type', data.mediaType),
          _row('Language', data.language),
          _row('Saved In', data.location, maxLines: 2),
          const SizedBox(height: 8),
          const Text(
            'Tags',
            style: TextStyle(
              color: Color(0xFF5D4747),
              fontWeight: FontWeight.w800,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 8),
          if (data.tags.isEmpty)
            const Text(
              'No tags yet',
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
                for (final tagLabel in data.tags) _tag(tagLabel),
                if (data.extraTagCount > 0) _tag('+${data.extraTagCount}'),
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
  final List<String> tags;
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
      artist: 'N/A',
      series: 'N/A',
      mediaType: 'Folder',
      language: 'N/A',
      location: location.isEmpty ? entry.folderRaw : location,
      updatedAt: _formatBrowseDateTime(entry.modifiedAt),
      sizeLabel: '-',
      pageInfo: null,
      tags: const <String>[],
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

    String joinOrFallback(List<String> values, {String fallback = 'N/A'}) {
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
        return 'Japanese';
      }
      if (hasLanguage(const <String>['english'])) {
        return 'English';
      }
      if (hasLanguage(const <String>['chinese'])) {
        return 'Chinese';
      }
      if (hasLanguage(const <String>['korean'])) {
        return 'Korean';
      }
      return 'N/A';
    }

    final artists = valuesFor(TagCategory.artist);
    final seriesValues = valuesFor(TagCategory.series);
    final mediaTypeValues = valuesFor(TagCategory.mediaType);
    final tagCandidates = <String>[];
    final seenTags = <String>{};
    for (final tag in tags) {
      if (tag.category == TagCategory.artist ||
          tag.category == TagCategory.series ||
          tag.category == TagCategory.mediaType) {
        continue;
      }
      final label = tag.name.trim();
      if (label.isEmpty || !seenTags.add(label.toLowerCase())) {
        continue;
      }
      tagCandidates.add(label);
    }

    final subtitle =
        artists.firstOrNull ??
        seriesValues.firstOrNull ??
        (entry.folderRaw.trim().isEmpty ? entry.displayName : entry.folderRaw);
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
          (entry.isPdf ? 'PDF' : entry.isImage ? 'Image' : 'Media'),
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
    _tagsFuture = widget.client.fetchItemTags(widget.entry.mediaId!);
    _metaFuture = widget.client.fetchMediaMeta(widget.entry.mediaId!);
    _imageFuture = widget.client.fetchImageDownload(widget.entry.mediaId!);
    _pdfPageBytes = null;
    _pdfPageError = null;
    _pdfPageNo = 1;
    _pdfTotalPages = null;
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
      final totalPages = await widget.client.resolvePdfPageCount(
        mediaId,
        pageCountHint: meta.pageCount,
      );
      if (!mounted || widget.entry.stableId != stableId) return;
      setState(() {
        _pdfTotalPages = totalPages;
        _pdfPageNo = _pdfPageNo.clamp(1, totalPages);
      });
    } catch (_) {
      // Keep the preview usable even when the server cannot report page counts.
    }
  }

  Future<void> _loadPdfPage(int pageNo) async {
    setState(() {
      _loadingPdfPage = true;
      _pdfPageError = null;
    });
    try {
      final bytes = await widget.client.fetchPdfPage(
        widget.entry.mediaId!,
        pageNo,
        width: 1600,
      );
      if (!mounted) return;
      setState(() {
        _pdfPageNo = pageNo;
        _pdfPageBytes = bytes;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _pdfPageError = error.toString();
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
    if (value == null) return 'N/A';
    final local = value.toLocal();
    final two = (int number) => number.toString().padLeft(2, '0');
    return '${local.year}/${two(local.month)}/${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }

  String _formatBytes(int? bytes) {
    if (bytes == null) return 'N/A';
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
              widget.entry.displayName,
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
                  label: Text(widget.entry.isPdf ? 'PDF' : 'Image'),
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
                            () => widget.client.openPdfInNewTab(
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
                    _detailRow('MIME', meta?.mimeType ?? 'N/A'),
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
      _leftFuture = null;
      _rightFuture = null;
      _syncPageFutures();
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final twoPage = prefs.getBool(_twoPagePrefsKey);
      final meta = await widget.client.fetchMediaMeta(mediaId);
      final totalPages = await widget.client.resolvePdfPageCount(
        mediaId,
        pageCountHint: meta.pageCount,
      );
      if (!mounted) return;
      setState(() {
        _twoPage = twoPage ?? _twoPage;
        _totalPages = totalPages.clamp(1, 1 << 30);
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
      return widget.client.fetchPdfPage(mediaId, pageNo, width: 1600);
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

  void _next() {
    final step = _twoPage ? 2 : 1;
    final next = _page + step;
    if (next <= _totalPages) {
      _setCurrentPage(next);
    }
  }

  void _prev() {
    final step = _twoPage ? 2 : 1;
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_twoPagePrefsKey, nextValue);
  }

  Future<void> _handleOpenDetail() async {
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
          fit: isSpread ? BoxFit.fitHeight : BoxFit.contain,
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
              const gap = 12.0;
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
                    const SizedBox(width: gap),
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
    final canNext = _page + (_twoPage ? 2 : 1) <= _totalPages;
    final pageText = '$_page/$_totalPages';

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

  @override
  Widget build(BuildContext context) {
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
                widget.entry.displayName,
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
    final sourceUrl = _urlController.text.trim();
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

    Navigator.of(context).pop(
      _WebUrlImportRequest(
        sourceUrl: _urlController.text.trim(),
        options: _options,
        importMetadata: _importMetadata,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
                  labelText: 'URL 一覧',
                  alignLabelWithHint: true,
                  hintText:
                      '1 行 1 件、またはカンマ区切りで複数 URL を入力\nhttps://hitomi.la/...\nhttps://kemono.su/...',
                  helperText: 'favorites だけで実行する場合は空でも構いません',
                ),
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
