import 'package:flutter/material.dart';

import '../database/tag_service.dart';
import '../models/metadata_settings.dart';
import '../services/host_api_server_service.dart';

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
    return showDialog<bool>(
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
  late AppMode _mode;
  late TextEditingController _clientUrlController;
  late TextEditingController _hostPortController;
  late TextEditingController _authTokenController;
  late bool _autoStartHostServer;

  MetadataConnectionStatus _status = MetadataConnectionStatus.unknown();
  bool _saving = false;
  bool _checking = false;
  bool _rescanning = false;
  bool _hostWorking = false;

  @override
  void initState() {
    super.initState();
    final settings = widget.tagService.settings;
    _mode = settings.appMode;
    _clientUrlController = TextEditingController(text: settings.clientApiBaseUrl);
    _hostPortController = TextEditingController(text: '${settings.hostPort}');
    _authTokenController = TextEditingController(text: settings.authToken ?? '');
    _autoStartHostServer = settings.autoStartHostServer;
    widget.hostServerService.refresh();
  }

  @override
  void dispose() {
    _clientUrlController.dispose();
    _hostPortController.dispose();
    _authTokenController.dispose();
    super.dispose();
  }

  MetadataSettings _draftSettings() {
    final parsedPort = int.tryParse(_hostPortController.text.trim());
    return MetadataSettings(
      appMode: _mode,
      clientApiBaseUrl: _clientUrlController.text.trim(),
      hostPort: parsedPort == null || parsedPort < 1 ? 8080 : parsedPort,
      authToken: _authTokenController.text.trim().isEmpty
          ? null
          : _authTokenController.text.trim(),
      autoStartHostServer: _autoStartHostServer,
    );
  }

  Future<void> _applyDraft() async {
    await widget.tagService.updateMetadataSettings(_draftSettings());
  }

  Future<void> _checkConnection() async {
    setState(() => _checking = true);
    try {
      final status = await widget.tagService.checkConnectionForSettings(
        _draftSettings(),
      );
      if (!mounted) return;
      setState(() => _status = status);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _status = MetadataConnectionStatus(
          state: MetadataConnectionState.disconnected,
          message: error.toString(),
          checkedAt: DateTime.now(),
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
        _status = MetadataConnectionStatus(
          state: draft.isStandaloneMode
              ? MetadataConnectionState.localMode
              : MetadataConnectionState.connected,
          message: draft.isStandaloneMode
              ? 'スタンドアロンモードでは再スキャンは不要です'
              : '再スキャン要求を送信しました',
          checkedAt: DateTime.now(),
        );
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _status = MetadataConnectionStatus(
          state: MetadataConnectionState.disconnected,
          message: error.toString(),
          checkedAt: DateTime.now(),
        );
      });
    } finally {
      if (mounted) {
        setState(() => _rescanning = false);
      }
    }
  }

  Future<void> _startHostServer() async {
    setState(() => _hostWorking = true);
    try {
      await _applyDraft();
      await widget.hostServerService.startServer(tagService: widget.tagService);
      await _checkConnection();
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
      if (!mounted) return;
      setState(() {
        _status = MetadataConnectionStatus(
          state: MetadataConnectionState.disconnected,
          message: 'ホストサーバーを停止しました',
          checkedAt: DateTime.now(),
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
      await _applyDraft();
      if (!mounted) return;
      Navigator.of(context).pop(true);
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

  String _hostStateLabel(HostServerState state) {
    switch (state) {
      case HostServerState.stopped:
        return '停止中';
      case HostServerState.starting:
        return '起動中';
      case HostServerState.running:
        return '稼働中';
      case HostServerState.stopping:
        return '停止中';
      case HostServerState.error:
        return 'エラー';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isClient = _mode == AppMode.client;
    final isHost = _mode == AppMode.host;

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
                value: _mode,
                decoration: const InputDecoration(labelText: '動作モード'),
                items: AppMode.values
                    .map(
                      (mode) => DropdownMenuItem(
                        value: mode,
                        child: Text(_appModeLabel(mode)),
                      ),
                    )
                    .toList(growable: false),
                onChanged: _saving
                    ? null
                    : (value) {
                        if (value == null) return;
                        setState(() => _mode = value);
                      },
              ),
              const SizedBox(height: 12),
              Text(
                switch (_mode) {
                  AppMode.standalone =>
                    'この端末のローカルファイルとローカルタグ DB をそのまま使います。',
                  AppMode.host =>
                    'この端末を正本ホストとして使います。ローカル UI はそのまま使い、API サーバー経由で外部クライアントを受け付けます。',
                  AppMode.client =>
                    'ホスト PC の HTTP API に接続して一覧・検索・閲覧・タグ更新・アップロードを行います。',
                },
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              if (isClient) ...[
                TextField(
                  controller: _clientUrlController,
                  enabled: !_saving,
                  decoration: const InputDecoration(
                    labelText: '接続先 URL',
                    hintText: '例: http://100.x.y.z:8080',
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Android では 127.0.0.1 / localhost ではなく、Tailscale IP または MagicDNS 名を指定してください。',
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
                    labelText: '待受ポート',
                    hintText: '例: 8080',
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
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _statusColor(context)),
                ),
                child: Text(
                  '接続状態: ${_status.message}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
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
                    onPressed: (_rescanning || _saving || _mode == AppMode.standalone)
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
                AnimatedBuilder(
                  animation: widget.hostServerService,
                  builder: (context, _) {
                    final hostStatus = widget.hostServerService.status;
                    final isRunning = hostStatus.state == HostServerState.running;
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
                          Text(hostStatus.message),
                          if (hostStatus.pid != null) ...[
                            const SizedBox(height: 4),
                            Text('PID: ${hostStatus.pid}'),
                          ],
                          if (hostStatus.endpoints.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            const Text('接続候補 URL'),
                            const SizedBox(height: 6),
                            for (final endpoint in hostStatus.endpoints)
                              SelectableText('${endpoint.label}: ${endpoint.url}'),
                          ],
                          if (hostStatus.tailscaleIpv4s.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(
                              'Tailscale IP: ${hostStatus.tailscaleIpv4s.join(', ')}',
                            ),
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
                            const Text('直近ログ'),
                            const SizedBox(height: 6),
                            Container(
                              constraints: const BoxConstraints(maxHeight: 140),
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.surfaceContainerHighest,
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
                ),
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
