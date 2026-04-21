import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../database/tag_service.dart';
import '../models/metadata_settings.dart';
import '../services/app_update_publish_service.dart';
import '../services/app_version_service.dart';
import '../services/controller_navigation_service.dart';
import '../services/host_api_server_service.dart';
import '../services/url_import_project_cookie_store_service.dart';

class MetadataSettingsDialog extends StatefulWidget {
  final TagService tagService;
  final HostApiServerService hostServerService;

  const MetadataSettingsDialog({
    super.key,
    required this.tagService,
    required this.hostServerService,
  });

  static Future<bool?> show(
    BuildContext context, {
    required TagService tagService,
    required HostApiServerService hostServerService,
  }) {
    return showControllerDialog<bool>(
      context: context,
      builder: (_) => MetadataSettingsDialog(
        tagService: tagService,
        hostServerService: hostServerService,
      ),
    );
  }

  @override
  State<MetadataSettingsDialog> createState() => _MetadataSettingsDialogState();
}

class _MetadataSettingsDialogState extends State<MetadataSettingsDialog> {
  late MetadataSettings _initialSettings;
  late AppMode _mode;
  late TextEditingController _clientUrlController;
  late TextEditingController _hostPortController;
  late TextEditingController _authTokenController;
  late TextEditingController _hostLibraryPathController;
  late TextEditingController _updateVersionController;
  late bool _autoStartHostServer;
  String? _defaultLibraryPath;
  bool _migrateLibrary = false;

  final UrlImportProjectCookieStoreService _projectCookieStore =
      UrlImportProjectCookieStoreService();

  Map<ProjectCookieProfile, ProjectCookieSlot> _projectCookieSlots =
      <ProjectCookieProfile, ProjectCookieSlot>{};

  MetadataConnectionStatus _status = MetadataConnectionStatus(
    state: MetadataConnectionState.unknown,
    message: '接続状態は未確認です。',
    checkedAt: DateTime.now(),
  );

  bool _saving = false;
  bool _checking = false;
  bool _rescanning = false;
  bool _hostWorking = false;
  bool _publishingUpdate = false;

  @override
  void initState() {
    super.initState();
    final settings = widget.tagService.settings;
    _initialSettings = settings;
    _mode = settings.appMode;
    _clientUrlController = TextEditingController(
      text: settings.clientApiBaseUrl,
    );
    _hostPortController = TextEditingController(text: '${settings.hostPort}');
    _authTokenController = TextEditingController(
      text: settings.authToken ?? '',
    );
    _hostLibraryPathController = TextEditingController(
      text: settings.hostLibraryPath,
    );
    _updateVersionController = TextEditingController(
      text: defaultAppUpdateVersion.trim(),
    );
    _autoStartHostServer = settings.autoStartHostServer;
    _status = settings.isStandaloneMode ? _localModeStatus() : _unknownStatus();
    widget.hostServerService.refresh();
    _loadDefaultUpdateVersion();
    _loadDefaultLibraryPath();
    _loadProjectCookies();
  }

  @override
  void dispose() {
    _clientUrlController.dispose();
    _hostPortController.dispose();
    _authTokenController.dispose();
    _hostLibraryPathController.dispose();
    _updateVersionController.dispose();
    super.dispose();
  }

  Future<void> _loadDefaultUpdateVersion() async {
    if (_updateVersionController.text.trim().isNotEmpty) return;
    final version = await AppVersionService().currentVersionLabel();
    if (!mounted || _updateVersionController.text.trim().isNotEmpty) return;
    setState(() => _updateVersionController.text = version);
  }

  MetadataConnectionStatus _unknownStatus() {
    return MetadataConnectionStatus(
      state: MetadataConnectionState.unknown,
      message: '接続状態は未確認です。',
      checkedAt: DateTime.now(),
    );
  }

  MetadataConnectionStatus _localModeStatus() {
    return MetadataConnectionStatus(
      state: MetadataConnectionState.localMode,
      message: 'スタンドアロンモードではローカル DB を使用します。',
      checkedAt: DateTime.now(),
    );
  }

  MetadataConnectionStatus _statusWithMessage(
    MetadataConnectionState state,
    String message,
  ) {
    return MetadataConnectionStatus(
      state: state,
      message: message,
      checkedAt: DateTime.now(),
    );
  }

  Future<void> _loadProjectCookies() async {
    final slots = await _projectCookieStore.loadSlots();
    if (!mounted) return;
    setState(() => _projectCookieSlots = slots);
  }

  Future<void> _loadDefaultLibraryPath() async {
    final defaultPath = await widget.hostServerService.resolveLibraryPath(
      const MetadataSettings(),
    );
    if (!mounted) return;
    setState(() {
      _defaultLibraryPath = defaultPath;
      _syncMigrationSelection();
    });
  }

  Future<void> _importProjectCookie(ProjectCookieProfile profile) async {
    try {
      final file = await openFile(
        acceptedTypeGroups: const <XTypeGroup>[
          XTypeGroup(label: 'Cookie files', extensions: <String>['txt']),
        ],
      );
      if (file == null) return;

      await _projectCookieStore.importCookieFile(profile, file.path);
      await _loadProjectCookies();
      _showSnackBar('${profile.label} の Cookie を登録しました');
    } catch (error) {
      _showSnackBar('${profile.label} の Cookie 登録に失敗しました: $error');
    }
  }

  Future<void> _removeProjectCookie(ProjectCookieProfile profile) async {
    try {
      await _projectCookieStore.deleteCookieFile(profile);
      await _loadProjectCookies();
      _showSnackBar('${profile.label} の Cookie を削除しました');
    } catch (error) {
      _showSnackBar('${profile.label} の Cookie 削除に失敗しました: $error');
    }
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _buildProjectCookieSection(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'URL 取り込み用 Cookie',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          Text(
            '選択した Cookie をアプリが利用できる保存先に保持します。URL 取り込みでは Auto / Kemono / Coomer / 共通 から選択できます。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          for (final profile in ProjectCookieProfile.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(profile.label),
                        const SizedBox(height: 2),
                        Text(
                          _projectCookieSummary(_projectCookieSlots[profile]),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _saving
                        ? null
                        : () => _importProjectCookie(profile),
                    child: Text(
                      _projectCookieSlots[profile]?.exists == true
                          ? '差し替え'
                          : '登録',
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: '削除',
                    onPressed:
                        (_saving ||
                            _projectCookieSlots[profile]?.exists != true)
                        ? null
                        : () => _removeProjectCookie(profile),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _projectCookieSummary(ProjectCookieSlot? slot) {
    if (slot == null || !slot.exists) {
      return '未設定';
    }

    final details = <String>[slot.path];
    if (slot.modifiedAt != null) {
      details.add('更新: ${_formatDateTime(slot.modifiedAt!)}');
    }
    return '設定済み: ${details.join(' / ')}';
  }

  MetadataSettings _draftSettings() {
    final parsedPort = int.tryParse(_hostPortController.text.trim());
    return MetadataSettings(
      appMode: _mode,
      clientApiBaseUrl: _clientUrlController.text.trim(),
      hostPort: parsedPort == null || parsedPort < 1 ? 8090 : parsedPort,
      authToken: _authTokenController.text.trim().isEmpty
          ? null
          : _authTokenController.text.trim(),
      autoStartHostServer: _autoStartHostServer,
      hostLibraryPath: _hostLibraryPathController.text.trim(),
    );
  }

  String _effectiveLibraryPathForSettings(MetadataSettings settings) {
    final configured = settings.hostLibraryPath.trim();
    if (configured.isNotEmpty) {
      return configured;
    }
    return _defaultLibraryPath ?? '';
  }

  String _normalizeComparablePath(String value) {
    final trimmed = value.trim().replaceAll('/', '\\');
    final isDriveRoot =
        trimmed.length == 3 &&
        trimmed.codeUnitAt(1) == 58 &&
        trimmed.endsWith('\\');
    if (trimmed.length > 3 && trimmed.endsWith('\\') && !isDriveRoot) {
      return trimmed.substring(0, trimmed.length - 1).toLowerCase();
    }
    return trimmed.toLowerCase();
  }

  bool _canOfferLibraryMigration(MetadataSettings draft) {
    if (!_initialSettings.isHostMode || !draft.isHostMode) {
      return false;
    }
    final sourcePath = _effectiveLibraryPathForSettings(_initialSettings);
    final targetPath = _effectiveLibraryPathForSettings(draft);
    if (sourcePath.isEmpty || targetPath.isEmpty) {
      return false;
    }
    return _normalizeComparablePath(sourcePath) !=
        _normalizeComparablePath(targetPath);
  }

  void _syncMigrationSelection() {
    if (!_canOfferLibraryMigration(_draftSettings())) {
      _migrateLibrary = false;
    }
  }

  Future<void> _pickHostLibraryFolder() async {
    try {
      final selected = await getDirectoryPath(
        confirmButtonText: 'Library フォルダに設定',
      );
      if (selected == null || selected.trim().isEmpty || !mounted) {
        return;
      }
      setState(() {
        _hostLibraryPathController.text = selected.trim();
        _syncMigrationSelection();
      });
    } catch (error) {
      _showSnackBar('Library フォルダの選択に失敗しました: $error');
    }
  }

  void _resetHostLibraryFolder() {
    setState(() {
      _hostLibraryPathController.clear();
      _syncMigrationSelection();
    });
  }

  Widget _buildLibraryFolderSection(BuildContext context) {
    final trimmed = _hostLibraryPathController.text.trim();
    final summary = trimmed.isEmpty
        ? '未設定なら既定の Library フォルダを使います。ホストモードでは共有先にも使われます。'
        : trimmed;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Library フォルダ', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: _hostLibraryPathController,
            enabled: !_saving,
            decoration: const InputDecoration(
              labelText: '保存先フォルダ',
              hintText: '未設定なら既定の Library フォルダを使用',
            ),
            onChanged: (_) => setState(_syncMigrationSelection),
          ),
          const SizedBox(height: 8),
          Text(
            summary,
            style: Theme.of(context).textTheme.bodySmall,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _saving ? null : _pickHostLibraryFolder,
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('フォルダを選択'),
              ),
              TextButton.icon(
                onPressed: (_saving || trimmed.isEmpty)
                    ? null
                    : _resetHostLibraryFolder,
                icon: const Icon(Icons.restart_alt),
                label: const Text('既定に戻す'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLibraryMigrationSection(
    BuildContext context,
    MetadataSettings draft,
  ) {
    final sourcePath = _effectiveLibraryPathForSettings(_initialSettings);
    final targetPath = _effectiveLibraryPathForSettings(draft);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _migrateLibrary,
            onChanged: _saving
                ? null
                : (value) => setState(() => _migrateLibrary = value ?? false),
            title: const Text('既存 Library を新しい保存先へ移行する'),
            subtitle: const Text(
              '保存先の変更だけではファイルは移動しません。チェックを入れた場合のみ、ホスト PC 上の Library を移行します。移行先は空フォルダ、または未作成パスに限定されます。',
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '移行元: $sourcePath',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Text(
            '移行先: $targetPath',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmLibraryMigration({
    required String sourcePath,
    required String targetPath,
  }) async {
    final confirmed = await showControllerDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Library を移行しますか'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('現在の Library を新しい保存先へ移動し、ホスト側のメタデータ参照先も更新します。'),
              const SizedBox(height: 12),
              Text('移行元: $sourcePath'),
              const SizedBox(height: 4),
              Text('移行先: $targetPath'),
              const SizedBox(height: 12),
              const Text('移行先は空フォルダ、または未作成パスのみ使用できます。'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('移行する'),
            ),
          ],
        );
      },
    );
    return confirmed == true;
  }

  Future<void> _applyDraft() async {
    await widget.tagService.updateMetadataSettings(_draftSettings());
  }

  Future<void> _checkConnection() async {
    setState(() {
      _checking = true;
      _status = _statusWithMessage(
        MetadataConnectionState.checking,
        '接続を確認しています...',
      );
    });

    try {
      final status = await widget.tagService.checkConnectionForSettings(
        _draftSettings(),
      );
      if (!mounted) return;
      setState(() => _status = status);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _status = _statusWithMessage(
          MetadataConnectionState.disconnected,
          error.toString(),
        );
      });
    } finally {
      if (mounted) {
        setState(() => _checking = false);
      }
    }
  }

  Future<void> _requestRescan() async {
    setState(() => _rescanning = true);
    try {
      final draft = _draftSettings();
      await widget.tagService.requestRescanForSettings(draft);
      if (!mounted) return;
      setState(() {
        _status = _statusWithMessage(
          draft.isStandaloneMode
              ? MetadataConnectionState.localMode
              : MetadataConnectionState.connected,
          draft.isStandaloneMode ? 'スタンドアロンモードでは再スキャンは不要です。' : '再スキャンを要求しました。',
        );
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _status = _statusWithMessage(
          MetadataConnectionState.disconnected,
          error.toString(),
        );
      });
    } finally {
      if (mounted) {
        setState(() => _rescanning = false);
      }
    }
  }

  Future<void> _publishAppUpdate() async {
    final draft = _draftSettings();
    final version = _updateVersionController.text.trim();
    if (draft.isStandaloneMode) {
      _showSnackBar('ホストまたはクライアントモードで実行してください');
      return;
    }
    if (version.isEmpty) {
      _showSnackBar('公開バージョンを入力してください');
      return;
    }

    final file = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(
          label: 'App update files',
          extensions: <String>[
            'apk',
            'aab',
            'zip',
            'msi',
            'msix',
            'exe',
            'dmg',
            'pkg',
          ],
        ),
      ],
    );
    if (file == null) return;

    setState(() => _publishingUpdate = true);
    try {
      final result = await const AppUpdatePublishService().uploadUpdate(
        settings: draft,
        version: version,
        filePath: file.path,
        fileName: file.name,
      );
      _showSnackBar('アップデートを公開しました: ${result.version}');
    } catch (error) {
      _showSnackBar('アップデート公開に失敗しました: $error');
    } finally {
      if (mounted) {
        setState(() => _publishingUpdate = false);
      }
    }
  }

  Future<void> _startHostServer() async {
    final draft = _draftSettings();
    if (_canOfferLibraryMigration(draft)) {
      _showSnackBar('Library フォルダの変更は保存から適用してください。移行する場合はチェックを入れて保存します。');
      return;
    }

    setState(() => _hostWorking = true);
    try {
      await _applyDraft();
      await widget.hostServerService.startServer(tagService: widget.tagService);
      await widget.hostServerService.refresh();
      await _checkConnection();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _status = _statusWithMessage(
          MetadataConnectionState.disconnected,
          'ホストサーバーの起動でエラーが発生しました: $error',
        );
      });
    } finally {
      if (mounted) {
        setState(() => _hostWorking = false);
      }
    }
  }

  Future<void> _stopHostServer() async {
    setState(() => _hostWorking = true);
    try {
      await widget.hostServerService.stopServer();
      await widget.hostServerService.refresh();
      if (!mounted) return;
      setState(() {
        _status = _statusWithMessage(
          MetadataConnectionState.disconnected,
          'ホストサーバーを停止しました。',
        );
      });
    } finally {
      if (mounted) {
        setState(() => _hostWorking = false);
      }
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final nextSettings = _draftSettings();
      if (_migrateLibrary && _canOfferLibraryMigration(nextSettings)) {
        final sourcePath = await widget.hostServerService.resolveLibraryPath(
          _initialSettings,
        );
        final targetPath = await widget.hostServerService.resolveLibraryPath(
          nextSettings,
        );
        final confirmed = await _confirmLibraryMigration(
          sourcePath: sourcePath,
          targetPath: targetPath,
        );
        if (!confirmed) {
          return;
        }
        await widget.hostServerService.migrateLibrary(
          fromSettings: _initialSettings,
          toSettings: nextSettings,
        );
      }
      await widget.tagService.updateMetadataSettings(nextSettings);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      _showSnackBar('設定の保存に失敗しました: $error');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Color _statusColor(BuildContext context) {
    switch (_status.state) {
      case MetadataConnectionState.connected:
        return Colors.green.shade400;
      case MetadataConnectionState.disconnected:
        return Theme.of(context).colorScheme.error;
      case MetadataConnectionState.localMode:
        return Theme.of(context).colorScheme.primary;
      case MetadataConnectionState.checking:
      case MetadataConnectionState.unknown:
        return Theme.of(context).colorScheme.outline;
    }
  }

  String _appModeLabel(AppMode mode) {
    switch (mode) {
      case AppMode.standalone:
        return 'スタンドアロン';
      case AppMode.host:
        return 'ホスト';
      case AppMode.client:
        return 'クライアント';
    }
  }

  String _appModeDescription(AppMode mode) {
    switch (mode) {
      case AppMode.standalone:
        return 'この PC だけでローカルフォルダとローカル DB を使います。';
      case AppMode.host:
        return 'この PC をホストとして使います。ローカル UI と API サーバーを同居させ、他端末から接続できるようにします。';
      case AppMode.client:
        return '別 PC のホスト API に接続して、検索・タグ・メタデータ更新をリモートで行います。';
    }
  }

  String _hostStateLabel(HostServerState state) {
    switch (state) {
      case HostServerState.stopped:
        return '停止中';
      case HostServerState.starting:
        return '起動中';
      case HostServerState.running:
        return '稼働中';
      case HostServerState.stopping:
        return '停止処理中';
      case HostServerState.error:
        return 'エラー';
    }
  }

  String _connectionStateLabel(MetadataConnectionState state) {
    switch (state) {
      case MetadataConnectionState.unknown:
        return '未確認';
      case MetadataConnectionState.checking:
        return '確認中';
      case MetadataConnectionState.connected:
        return '接続済み';
      case MetadataConnectionState.disconnected:
        return '未接続';
      case MetadataConnectionState.localMode:
        return 'ローカル';
    }
  }

  String _fallbackConnectionMessage(MetadataConnectionState state) {
    switch (state) {
      case MetadataConnectionState.unknown:
        return '接続状態は未確認です。';
      case MetadataConnectionState.checking:
        return '接続を確認しています...';
      case MetadataConnectionState.connected:
        return '接続できています。';
      case MetadataConnectionState.disconnected:
        return '接続できません。設定内容を確認してください。';
      case MetadataConnectionState.localMode:
        return 'スタンドアロンモードではローカル DB を使用します。';
    }
  }

  String _fallbackHostMessage(HostServerState state) {
    switch (state) {
      case HostServerState.stopped:
        return 'ホストサーバーは停止しています。';
      case HostServerState.starting:
        return 'ホストサーバーを起動しています...';
      case HostServerState.running:
        return 'ホストサーバーは起動中です。';
      case HostServerState.stopping:
        return 'ホストサーバーを停止しています...';
      case HostServerState.error:
        return 'ホストサーバーでエラーが発生しました。';
    }
  }

  bool _looksLikeMojibake(String value) {
    const patterns = <String>[
      '繝',
      '繧',
      '縺',
      '荳',
      '譛',
      '逋ｻ',
      '讀懃ｴ｢',
      '驕',
      '蜑',
      '隧',
      '邏',
      '陦',
      '遉',
      '莉ｶ',
      '蠖',
      '閾',
      '髢',
      '繝帙',
      '�',
    ];
    return patterns.any(value.contains);
  }

  String _safeMessage(String raw, {required String fallback}) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty || _looksLikeMojibake(trimmed)) {
      return fallback;
    }
    return trimmed;
  }

  String _formatDateTime(DateTime value) {
    final year = value.year.toString().padLeft(4, '0');
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    return '$year/$month/$day $hour:$minute';
  }

  Widget _buildConnectionStatusCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _statusColor(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('接続状態', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(
            _safeMessage(
              _status.message,
              fallback: _fallbackConnectionMessage(_status.state),
            ),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          Text(
            '状態: ${_connectionStateLabel(_status.state)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          Text(
            '最終確認: ${_formatDateTime(_status.checkedAt)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildDeveloperUpdateSection(
    BuildContext context,
    MetadataSettings draft,
  ) {
    final target = draft.isHostMode
        ? draft.hostLoopbackApiBaseUrl
        : draft.remoteApiBaseUrl.trim();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('開発ビルド公開', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: _updateVersionController,
            enabled: !_saving && !_publishingUpdate,
            decoration: const InputDecoration(
              labelText: '公開バージョン',
              hintText: '例: 1.0.2+3',
            ),
          ),
          const SizedBox(height: 8),
          Text(
            target.isEmpty ? '公開先: 未設定' : '公開先: $target',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: (_saving || _publishingUpdate)
                  ? null
                  : _publishAppUpdate,
              icon: _publishingUpdate
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.upload_file),
              label: Text(_publishingUpdate ? '公開中...' : 'ファイルを公開'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHostStatusCard(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.hostServerService,
      builder: (context, _) {
        final hostStatus = widget.hostServerService.status;
        final isRunning = hostStatus.state == HostServerState.running;
        final hostMessage = _safeMessage(
          hostStatus.message,
          fallback: _fallbackHostMessage(hostStatus.state),
        );

        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Theme.of(context).colorScheme.outline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'ホストサーバー: ${_hostStateLabel(hostStatus.state)}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              Text(hostMessage),
              if (hostStatus.pid != null) ...[
                const SizedBox(height: 4),
                Text('PID: ${hostStatus.pid}'),
              ],
              if (hostStatus.endpoints.isNotEmpty) ...[
                const SizedBox(height: 8),
                const Text('接続先 URL'),
                const SizedBox(height: 6),
                for (final endpoint in hostStatus.endpoints)
                  SelectableText('${endpoint.label}: ${endpoint.url}'),
              ],
              if (hostStatus.tailscaleIpv4s.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('Tailscale IP: ${hostStatus.tailscaleIpv4s.join(', ')}'),
              ],
              if (hostStatus.localIpv4s.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text('Local IPv4: ${hostStatus.localIpv4s.join(', ')}'),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: (_saving || _hostWorking || isRunning)
                        ? null
                        : _startHostServer,
                    icon: _hostWorking && !isRunning
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.play_arrow),
                    label: const Text('サーバー起動'),
                  ),
                  OutlinedButton.icon(
                    onPressed: (_saving || _hostWorking || !isRunning)
                        ? null
                        : _stopHostServer,
                    icon: _hostWorking && isRunning
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.stop),
                    label: const Text('サーバー停止'),
                  ),
                ],
              ),
              if (hostStatus.logLines.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('最近のログ'),
                const SizedBox(height: 6),
                Container(
                  constraints: const BoxConstraints(maxHeight: 140),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      hostStatus.logLines.join('\n'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final draft = _draftSettings();
    final isClient = _mode == AppMode.client;
    final isHost = _mode == AppMode.host;
    final usesLocalLibrary = _mode != AppMode.client;
    final showLibraryMigration = _canOfferLibraryMigration(draft);

    return AlertDialog(
      title: const Text('動作モード設定'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<AppMode>(
                initialValue: _mode,
                decoration: const InputDecoration(labelText: '動作モード'),
                items: AppMode.values
                    .map(
                      (mode) => DropdownMenuItem<AppMode>(
                        value: mode,
                        child: Text(_appModeLabel(mode)),
                      ),
                    )
                    .toList(growable: false),
                onChanged: _saving
                    ? null
                    : (value) {
                        if (value == null) return;
                        setState(() {
                          _mode = value;
                          if (value == AppMode.standalone) {
                            _status = _localModeStatus();
                          } else if (_status.state ==
                              MetadataConnectionState.localMode) {
                            _status = _unknownStatus();
                          }
                          _syncMigrationSelection();
                        });
                      },
              ),
              const SizedBox(height: 12),
              Text(
                _appModeDescription(_mode),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              if (isClient) ...[
                TextField(
                  controller: _clientUrlController,
                  enabled: !_saving,
                  decoration: const InputDecoration(
                    labelText: '接続先 API URL',
                    hintText: '例: http://100.x.y.z:8090',
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Android では 127.0.0.1 / localhost は使えません。Tailscale IP または MagicDNS 名を指定してください。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
              ],
              if (isHost) ...[
                TextField(
                  controller: _hostPortController,
                  enabled: !_saving,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'ホストポート',
                    hintText: '例: 8090',
                  ),
                ),
                const SizedBox(height: 12),
                SwitchListTile.adaptive(
                  value: _autoStartHostServer,
                  onChanged: _saving
                      ? null
                      : (value) => setState(() => _autoStartHostServer = value),
                  title: const Text('ホストモードで自動起動'),
                  contentPadding: EdgeInsets.zero,
                ),
                const SizedBox(height: 12),
              ],
              if (usesLocalLibrary) ...[
                _buildLibraryFolderSection(context),
                if (showLibraryMigration) ...[
                  const SizedBox(height: 12),
                  _buildLibraryMigrationSection(context, draft),
                ],
                const SizedBox(height: 12),
              ],
              TextField(
                controller: _authTokenController,
                enabled: !_saving,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '認証トークン',
                  hintText: '未設定なら認証なしで接続します',
                ),
              ),
              const SizedBox(height: 12),
              _buildProjectCookieSection(context),
              const SizedBox(height: 12),
              if (!draft.isStandaloneMode) ...[
                _buildDeveloperUpdateSection(context, draft),
                const SizedBox(height: 12),
              ],
              _buildConnectionStatusCard(context),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _checking || _saving ? null : _checkConnection,
                    icon: _checking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.network_check),
                    label: const Text('接続確認'),
                  ),
                  OutlinedButton.icon(
                    onPressed:
                        (_rescanning || _saving || _mode == AppMode.standalone)
                        ? null
                        : _requestRescan,
                    icon: _rescanning
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.sync),
                    label: const Text('再スキャン'),
                  ),
                ],
              ),
              if (isHost) ...[
                const SizedBox(height: 16),
                _buildHostStatusCard(context),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中...' : '保存'),
        ),
      ],
    );
  }
}
