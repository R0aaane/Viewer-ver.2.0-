import 'package:flutter/material.dart';

import '../database/tag_service.dart';
import '../models/metadata_settings.dart';

class MetadataSettingsDialog extends StatefulWidget {
  final TagService tagService;

  const MetadataSettingsDialog({
    super.key,
    required this.tagService,
  });

  static Future<bool?> show(
    BuildContext context, {
    required TagService tagService,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (_) => MetadataSettingsDialog(tagService: tagService),
    );
  }

  @override
  State<MetadataSettingsDialog> createState() => _MetadataSettingsDialogState();
}

class _MetadataSettingsDialogState extends State<MetadataSettingsDialog> {
  late MetadataStorageMode _mode;
  late TextEditingController _apiUrlController;
  late TextEditingController _authTokenController;
  MetadataConnectionStatus _status = MetadataConnectionStatus.unknown();
  bool _saving = false;
  bool _checking = false;
  bool _rescanning = false;

  @override
  void initState() {
    super.initState();
    final settings = widget.tagService.settings;
    _mode = settings.storageMode;
    _apiUrlController = TextEditingController(text: settings.remoteApiBaseUrl);
    _authTokenController = TextEditingController(text: settings.authToken ?? '');
  }

  @override
  void dispose() {
    _apiUrlController.dispose();
    _authTokenController.dispose();
    super.dispose();
  }

  Future<void> _checkConnection() async {
    setState(() => _checking = true);
    try {
      final draft = MetadataSettings(
        storageMode: _mode,
        remoteApiBaseUrl: _apiUrlController.text.trim(),
        authToken: _authTokenController.text.trim().isEmpty
            ? null
            : _authTokenController.text.trim(),
      );

      final status = await widget.tagService.checkConnectionForSettings(draft);
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
      final draft = MetadataSettings(
        storageMode: _mode,
        remoteApiBaseUrl: _apiUrlController.text.trim(),
        authToken: _authTokenController.text.trim().isEmpty
            ? null
            : _authTokenController.text.trim(),
      );

      await widget.tagService.requestRescanForSettings(draft);
      if (!mounted) return;
      setState(() {
        _status = MetadataConnectionStatus(
          state: _mode == MetadataStorageMode.remote
              ? MetadataConnectionState.connected
              : MetadataConnectionState.localMode,
          message: _mode == MetadataStorageMode.remote
              ? '再スキャンを要求しました'
              : 'ローカルモードでは再スキャンは不要です',
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

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.tagService.updateMetadataSettings(
        MetadataSettings(
          storageMode: _mode,
          remoteApiBaseUrl: _apiUrlController.text.trim(),
          authToken: _authTokenController.text.trim().isEmpty
              ? null
              : _authTokenController.text.trim(),
        ),
      );
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

  @override
  Widget build(BuildContext context) {
    final isRemote = _mode == MetadataStorageMode.remote;

    return AlertDialog(
      title: const Text('メタデータ設定'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<MetadataStorageMode>(
                value: _mode,
                decoration: const InputDecoration(
                  labelText: '保存モード',
                ),
                items: const [
                  DropdownMenuItem(
                    value: MetadataStorageMode.local,
                    child: Text('ローカルメタデータ'),
                  ),
                  DropdownMenuItem(
                    value: MetadataStorageMode.remote,
                    child: Text('リモートメタデータ'),
                  ),
                ],
                onChanged: _saving
                    ? null
                    : (value) {
                        if (value == null) return;
                        setState(() => _mode = value);
                      },
              ),
              const SizedBox(height: 12),
              Text(
                isRemote
                    ? '画像/PDF 本体は共有フォルダから直接開き、タグや検索は API 経由で扱います。'
                    : 'タグ情報はこの端末のローカル DB に保存します。既存互換を優先するモードです。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _apiUrlController,
                enabled: !_saving,
                decoration: const InputDecoration(
                  labelText: 'リモート API の URL',
                  hintText: '例: http://192.168.0.10:8080',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _authTokenController,
                enabled: !_saving,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '認証トークン（任意）',
                  hintText: '将来の認証追加に備えた設定です',
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
                    onPressed: _rescanning || _saving ? null : _requestRescan,
                    icon: _rescanning
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.sync),
                    label: const Text('再スキャン要求'),
                  ),
                ],
              ),
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
