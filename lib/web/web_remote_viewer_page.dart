// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:html' as html;
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/metadata_settings.dart';
import '../models/tag.dart';
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
    if (entry.isPdf) {
      await _openPdfViewerPage(entry);
      return;
    }
    if (splitView) {
      return;
    }
    await _openDetailPage(entry);
  }

  Future<void> _applyTagQuery(String query) async {
    _searchController.text = query;
    await _loadEntries();
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
              if (_isConnecting || _isLoading)
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
          parentFolderAvailable: parentFolder != null,
          onSearch: _loadEntries,
          onGoParent: parentFolder == null ? null : () => _selectFolder(parentFolder),
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
  final bool parentFolderAvailable;
  final Future<void> Function() onSearch;
  final VoidCallback? onGoParent;
  final _WebMediaFilter filter;
  final ValueChanged<_WebMediaFilter> onFilterChanged;

  const _BrowserHeader({
    required this.folderName,
    required this.itemCount,
    required this.searchController,
    required this.isLoading,
    required this.parentFolderAvailable,
    required this.onSearch,
    required this.onGoParent,
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

  const _EntryCard({
    required this.client,
    required this.entry,
    required this.selected,
    required this.onTap,
    required this.folderName,
  });

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 760;
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF1E3F69) : const Color(0xFF171A1F),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? const Color(0xFF74B4FF) : Colors.white12,
          ),
        ),
        child:
            compact
                ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _EntryHeader(entry: entry, folderName: folderName),
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        _RemoteThumbnail(client: client, entry: entry),
                        const SizedBox(width: 12),
                        Expanded(child: _EntryMeta(entry: entry)),
                      ],
                    ),
                  ],
                )
                : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _RemoteThumbnail(client: client, entry: entry),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          _EntryHeader(entry: entry, folderName: folderName),
                          const SizedBox(height: 12),
                          _EntryMeta(entry: entry),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Icon(Icons.chevron_right, color: Colors.white60),
                    ),
                  ],
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
    if (widget.entry.isPdf) {
      _loadPdfPage(1);
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
                        onPressed: _pdfPageNo > 1 ? () => _loadPdfPage(_pdfPageNo - 1) : null,
                        icon: const Icon(Icons.chevron_left),
                        label: const Text('前へ'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _loadingPdfPage ? null : () => _loadPdfPage(_pdfPageNo + 1),
                        icon: const Icon(Icons.chevron_right),
                        label: const Text('次へ'),
                      ),
                      Text(
                        'ページ $_pdfPageNo',
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
  String? _objectUrl;
  Object? _loadError;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadPdf();
  }

  @override
  void didUpdateWidget(covariant WebPdfViewerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.stableId != widget.entry.stableId) {
      _releaseObjectUrl();
      _loadPdf();
    }
  }

  Future<void> _loadPdf() async {
    final mediaId = widget.entry.mediaId;
    if (mediaId == null || mediaId.isEmpty) {
      setState(() {
        _loadError = StateError('PDF を開くための mediaId がありません');
        _loading = false;
      });
      return;
    }

    setState(() {
      _loading = true;
      _loadError = null;
    });

    try {
      final objectUrl = await widget.client.createPdfObjectUrl(mediaId);
      if (!mounted) {
        widget.client.revokeObjectUrl(objectUrl);
        return;
      }
      _releaseObjectUrl();
      setState(() {
        _objectUrl = objectUrl;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error;
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  void _releaseObjectUrl() {
    final objectUrl = _objectUrl;
    if (objectUrl == null) return;
    widget.client.revokeObjectUrl(objectUrl);
    _objectUrl = null;
  }

  Future<void> _handleOpenDetail() async {
    final onOpenDetail = widget.onOpenDetail;
    if (onOpenDetail == null) return;
    await onOpenDetail();
  }

  @override
  void dispose() {
    _releaseObjectUrl();
    super.dispose();
  }

  Widget _buildViewerBody() {
    if (_loading && _objectUrl == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'PDF 表示ページを読み込めませんでした: $_loadError',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.red.shade200),
          ),
        ),
      );
    }
    final objectUrl = _objectUrl;
    if (objectUrl == null) {
      return const Center(
        child: Text('PDF データがありません', style: TextStyle(color: Colors.white70)),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: _EmbeddedPdfView(
        objectUrl: objectUrl,
        title: widget.entry.displayName,
      ),
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
            onPressed:
                widget.entry.mediaId == null
                    ? null
                    : () => widget.client.openPdfInNewTab(widget.entry.mediaId!),
            tooltip: '別タブで開く',
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
                ],
              ),
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

class _EmbeddedPdfView extends StatefulWidget {
  final String objectUrl;
  final String title;

  const _EmbeddedPdfView({
    required this.objectUrl,
    required this.title,
  });

  @override
  State<_EmbeddedPdfView> createState() => _EmbeddedPdfViewState();
}

class _EmbeddedPdfViewState extends State<_EmbeddedPdfView> {
  static int _nextViewId = 0;

  late final String _viewType;
  late final html.IFrameElement _iframe;

  @override
  void initState() {
    super.initState();
    _viewType = 'web-embedded-pdf-${_nextViewId++}';
    _iframe =
        html.IFrameElement()
          ..style.border = '0'
          ..style.width = '100%'
          ..style.height = '100%'
          ..style.backgroundColor = '#0E1117'
          ..src = _viewerUrl(widget.objectUrl)
          ..title = widget.title;
    ui_web.platformViewRegistry.registerViewFactory(
      _viewType,
      (viewId) => _iframe,
    );
  }

  @override
  void didUpdateWidget(covariant _EmbeddedPdfView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.objectUrl != widget.objectUrl) {
      _iframe.src = _viewerUrl(widget.objectUrl);
    }
    if (oldWidget.title != widget.title) {
      _iframe.title = widget.title;
    }
  }

  String _viewerUrl(String objectUrl) => '$objectUrl#toolbar=1&navpanes=0';

  @override
  Widget build(BuildContext context) {
    return HtmlElementView(viewType: _viewType);
  }
}

class _RemoteThumbnail extends StatefulWidget {
  final WebRemoteApiClient? client;
  final WebRemoteEntry entry;

  const _RemoteThumbnail({
    required this.client,
    required this.entry,
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
      width: 240,
      height: 320,
      page: widget.entry.isPdf ? 1 : null,
    );
  }

  Widget _shell(Widget child) {
    return Container(
      width: 132,
      height: 184,
      decoration: BoxDecoration(
        color: const Color(0xFF0F141C),
        borderRadius: BorderRadius.circular(14),
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
          borderRadius: BorderRadius.circular(14),
          child: Image.memory(
            bytes,
            width: 132,
            height: 184,
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
