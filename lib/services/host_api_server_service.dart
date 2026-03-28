import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/tag_service.dart';
import '../models/metadata_settings.dart';
import 'app_settings_service.dart';
import 'remote_tag_api_client.dart';

enum HostServerState {
  stopped,
  starting,
  running,
  stopping,
  error,
}

class HostAccessEndpoint {
  final String label;
  final String url;

  const HostAccessEndpoint({
    required this.label,
    required this.url,
  });
}

class HostServerStatus {
  final HostServerState state;
  final String message;
  final int? pid;
  final int port;
  final String hostname;
  final List<String> localIpv4s;
  final List<String> tailscaleIpv4s;
  final List<HostAccessEndpoint> endpoints;
  final List<String> logLines;
  final DateTime updatedAt;

  const HostServerStatus({
    required this.state,
    required this.message,
    required this.pid,
    required this.port,
    required this.hostname,
    required this.localIpv4s,
    required this.tailscaleIpv4s,
    required this.endpoints,
    required this.logLines,
    required this.updatedAt,
  });

  factory HostServerStatus.initial() {
    return HostServerStatus(
      state: HostServerState.stopped,
      message: 'サーバーは停止しています',
      pid: null,
      port: 8080,
      hostname: '',
      localIpv4s: const <String>[],
      tailscaleIpv4s: const <String>[],
      endpoints: const <HostAccessEndpoint>[],
      logLines: const <String>[],
      updatedAt: DateTime.now(),
    );
  }

  HostServerStatus copyWith({
    HostServerState? state,
    String? message,
    int? pid,
    bool clearPid = false,
    int? port,
    String? hostname,
    List<String>? localIpv4s,
    List<String>? tailscaleIpv4s,
    List<HostAccessEndpoint>? endpoints,
    List<String>? logLines,
    DateTime? updatedAt,
  }) {
    return HostServerStatus(
      state: state ?? this.state,
      message: message ?? this.message,
      pid: clearPid ? null : (pid ?? this.pid),
      port: port ?? this.port,
      hostname: hostname ?? this.hostname,
      localIpv4s: localIpv4s ?? this.localIpv4s,
      tailscaleIpv4s: tailscaleIpv4s ?? this.tailscaleIpv4s,
      endpoints: endpoints ?? this.endpoints,
      logLines: logLines ?? this.logLines,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }
}

class HostApiServerService extends ChangeNotifier {
  static const String _foldersPrefsKey = 'prefs.folders';
  static const String _installHint =
      'ユーザーのターミナルで `pip install -r requirements.txt` または '
      '`py -m pip install -r requirements.txt` を実行してください';

  final AppSettingsService _settingsService = AppSettingsService();

  HostServerStatus _status = HostServerStatus.initial();
  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;

  HostServerStatus get status => _status;

  Future<void> refresh() async {
    final settings = await _settingsService.loadMetadataSettings();
    final networkInfo = await _loadNetworkInfo(settings.hostPort);
    final health = await _checkHealth(settings);
    final externalRunning =
        _process == null &&
        settings.isHostMode &&
        health.state == MetadataConnectionState.connected;

    _status = _status.copyWith(
      state: _process != null
          ? (health.state == MetadataConnectionState.connected
                ? HostServerState.running
                : _status.state)
          : (externalRunning ? HostServerState.running : _status.state),
      message: _process != null
          ? health.message
          : (externalRunning ? '既存の API サーバーに接続できました' : _status.message),
      port: settings.hostPort,
      hostname: networkInfo.hostname,
      localIpv4s: networkInfo.localIpv4s,
      tailscaleIpv4s: networkInfo.tailscaleIpv4s,
      endpoints: networkInfo.endpoints,
      updatedAt: DateTime.now(),
    );
    notifyListeners();
  }

  Future<void> startServer({TagService? tagService}) async {
    final settings = await _settingsService.loadMetadataSettings();

    if (!Platform.isWindows) {
      _setStatus(
        _status.copyWith(
          state: HostServerState.error,
          message: 'ホストモードの内蔵サーバー起動は現在 Windows のみ対応です',
          clearPid: true,
          port: settings.hostPort,
        ),
      );
      return;
    }

    if (!settings.isHostMode) {
      _setStatus(
        _status.copyWith(
          state: HostServerState.error,
          message: 'ホストモードに切り替えてからサーバーを起動してください',
          clearPid: true,
          port: settings.hostPort,
        ),
      );
      return;
    }

    final existingHealth = await _checkHealth(settings);
    if (existingHealth.state == MetadataConnectionState.connected) {
      final networkInfo = await _loadNetworkInfo(settings.hostPort);
      _setStatus(
        _status.copyWith(
          state: HostServerState.running,
          message: '既存の API サーバーに接続できました',
          clearPid: true,
          port: settings.hostPort,
          hostname: networkInfo.hostname,
          localIpv4s: networkInfo.localIpv4s,
          tailscaleIpv4s: networkInfo.tailscaleIpv4s,
          endpoints: networkInfo.endpoints,
        ),
      );
      return;
    }

    if (_process != null) {
      await refresh();
      return;
    }

    final roots = await _loadMediaRoots();
    if (roots.isEmpty) {
      _setStatus(
        _status.copyWith(
          state: HostServerState.error,
          message: '共有対象フォルダが未設定です。先にライブラリまたは対象フォルダを登録してください',
          clearPid: true,
          port: settings.hostPort,
        ),
      );
      return;
    }

    _setStatus(
      _status.copyWith(
        state: HostServerState.starting,
        message: 'API サーバーを起動しています...',
        clearPid: true,
        port: settings.hostPort,
      ),
    );

    final env = await _buildEnvironment(settings, roots);
    final process = await _startPythonServer(
      port: settings.hostPort,
      environment: env,
    );
    if (process == null) {
      _setStatus(
        _status.copyWith(
          state: HostServerState.error,
          message: 'ホスト API の起動に必要な Python 依存関係が見つかりません。$_installHint',
          clearPid: true,
          port: settings.hostPort,
        ),
      );
      return;
    }

    _process = process;
    _attachLogs(process);
    unawaited(_watchExit(process));

    final healthy = await _waitUntilHealthy(settings);
    if (!healthy) {
      await stopServer();
      _setStatus(
        _status.copyWith(
          state: HostServerState.error,
          message: 'サーバー起動後の疎通確認に失敗しました',
          clearPid: true,
          port: settings.hostPort,
        ),
      );
      return;
    }

    if (tagService != null) {
      await tagService.syncLocalTagsToHost();
    }

    final networkInfo = await _loadNetworkInfo(settings.hostPort);
    _setStatus(
      _status.copyWith(
        state: HostServerState.running,
        message: 'API サーバーが起動しました',
        pid: process.pid,
        port: settings.hostPort,
        hostname: networkInfo.hostname,
        localIpv4s: networkInfo.localIpv4s,
        tailscaleIpv4s: networkInfo.tailscaleIpv4s,
        endpoints: networkInfo.endpoints,
      ),
    );
  }

  Future<void> stopServer() async {
    final process = _process;
    if (process == null) {
      _setStatus(
        _status.copyWith(
          state: HostServerState.stopped,
          message: 'サーバーは停止しています',
          clearPid: true,
        ),
      );
      return;
    }

    _setStatus(
      _status.copyWith(
        state: HostServerState.stopping,
        message: 'API サーバーを停止しています...',
      ),
    );

    try {
      process.kill();
      await process.exitCode.timeout(const Duration(seconds: 5));
    } catch (_) {}

    await _disposeProcess();
    _setStatus(
      _status.copyWith(
        state: HostServerState.stopped,
        message: 'サーバーを停止しました',
        clearPid: true,
      ),
    );
  }

  Future<MetadataConnectionStatus> checkServerConnection() async {
    final settings = await _settingsService.loadMetadataSettings();
    return _checkHealth(settings);
  }

  Future<void> requestRescan() async {
    final settings = await _settingsService.loadMetadataSettings();
    final client = _loopbackClient(settings);
    await client.requestRescan();
  }

  Future<void> _watchExit(Process process) async {
    final exitCode = await process.exitCode;
    if (!identical(_process, process)) {
      return;
    }
    await _disposeProcess();
    _setStatus(
      _status.copyWith(
        state: exitCode == 0 ? HostServerState.stopped : HostServerState.error,
        message: exitCode == 0
            ? 'サーバーが停止しました'
            : _deriveProcessFailureMessage(exitCode),
        clearPid: true,
      ),
    );
  }

  Future<void> _disposeProcess() async {
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _stdoutSubscription = null;
    _stderrSubscription = null;
    _process = null;
  }

  void _attachLogs(Process process) {
    _stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _appendLog('[stdout] $line'));
    _stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _appendLog('[stderr] $line'));
  }

  void _appendLog(String line) {
    final nextLogs = List<String>.from(_status.logLines)..add(line);
    while (nextLogs.length > 40) {
      nextLogs.removeAt(0);
    }
    _setStatus(_status.copyWith(logLines: nextLogs));
  }

  Future<Process?> _startPythonServer({
    required int port,
    required Map<String, String> environment,
  }) async {
    final workdir = Directory.current.path;
    final commands = <List<String>>[
      <String>['python', '-m', 'uvicorn', 'server.main:app', '--host', '0.0.0.0', '--port', '$port'],
      <String>['py', '-m', 'uvicorn', 'server.main:app', '--host', '0.0.0.0', '--port', '$port'],
    ];

    for (final command in commands) {
      final launcher = command.first;
      final available = await _canLaunchServerWith(
        launcher,
        workdir: workdir,
        environment: environment,
      );
      if (!available) {
        continue;
      }

      try {
        return await Process.start(
          launcher,
          command.sublist(1),
          workingDirectory: workdir,
          environment: environment,
          runInShell: true,
        );
      } on ProcessException catch (error) {
        _appendLog('[start] $launcher: ${error.message}');
      }
    }
    return null;
  }

  Future<bool> _canLaunchServerWith(
    String launcher, {
    required String workdir,
    required Map<String, String> environment,
  }) async {
    try {
      final result = await Process.run(
        launcher,
        const <String>['-c', 'import uvicorn, server.main'],
        workingDirectory: workdir,
        environment: environment,
        runInShell: true,
      );
      if (result.exitCode == 0) {
        return true;
      }

      final stderr = '${result.stderr}'.trim();
      final stdout = '${result.stdout}'.trim();
      final detail = stderr.isNotEmpty ? stderr : stdout;
      if (detail.isNotEmpty) {
        _appendLog('[start] $launcher: ${_singleLine(detail)}');
      } else {
        _appendLog('[start] $launcher: 起動前チェックに失敗しました');
      }
      return false;
    } on ProcessException catch (error) {
      _appendLog('[start] $launcher: ${error.message}');
      return false;
    }
  }

  String _deriveProcessFailureMessage(int exitCode) {
    final recent = _status.logLines.join('\n').toLowerCase();
    if (recent.contains('no module named uvicorn')) {
      return 'uvicorn が見つかりません。$_installHint';
    }
    if (recent.contains('no module named fastapi')) {
      return 'fastapi が見つかりません。$_installHint';
    }
    if (recent.contains('no module named pydantic') ||
        recent.contains('no module named pil') ||
        recent.contains('no module named pypdfium2')) {
      return 'ホスト API の依存関係が不足しています。$_installHint';
    }
    if (recent.contains('no module named server')) {
      return 'server パッケージを読み込めません。プロジェクトルートからアプリを起動してください';
    }
    return 'サーバープロセスが終了しました (exit=$exitCode)';
  }

  String _singleLine(String raw) {
    return raw.replaceAll('\r', ' ').replaceAll('\n', ' ').trim();
  }

  Future<bool> _waitUntilHealthy(MetadataSettings settings) async {
    for (var attempt = 0; attempt < 30; attempt++) {
      final status = await _checkHealth(settings);
      if (status.state == MetadataConnectionState.connected) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return false;
  }

  Future<Map<String, String>> _buildEnvironment(
    MetadataSettings settings,
    List<String> roots,
  ) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final dataDir = Directory('${docsDir.path}${Platform.pathSeparator}host_api');
    if (!await dataDir.exists()) {
      await dataDir.create(recursive: true);
    }

    final env = Map<String, String>.from(Platform.environment);
    env['MEDIA_SERVER_HOST'] = '0.0.0.0';
    env['MEDIA_SERVER_PORT'] = '${settings.hostPort}';
    env['MEDIA_SERVER_MEDIA_ROOTS'] = roots.join(';');
    env['MEDIA_SERVER_AUTH_TOKEN'] = settings.authToken?.trim() ?? '';
    env['MEDIA_SERVER_DATA_DIR'] = dataDir.path;
    env['MEDIA_SERVER_STARTUP_RESCAN'] = 'true';
    env['MEDIA_SERVER_CORS_ORIGINS'] =
        'http://127.0.0.1;http://localhost;http://${Platform.localHostname}';
    return env;
  }

  Future<List<String>> _loadMediaRoots() async {
    final prefs = await SharedPreferences.getInstance();
    final roots = <String>[
      ...(prefs.getStringList(_foldersPrefsKey) ?? const <String>[])
          .where((entry) => entry.trim().isNotEmpty && !entry.startsWith('content://')),
    ].toSet().toList(growable: true);

    final docsDir = await getApplicationDocumentsDirectory();
    final libraryPath = '${docsDir.path}${Platform.pathSeparator}library';
    final libraryDir = Directory(libraryPath);
    if (!await libraryDir.exists()) {
      await libraryDir.create(recursive: true);
    }
    if (!roots.contains(libraryPath)) {
      roots.insert(0, libraryPath);
    }

    final existingRoots = <String>[];
    for (final root in roots) {
      try {
        if (await Directory(root).exists()) {
          existingRoots.add(root);
        }
      } catch (_) {}
    }
    return existingRoots;
  }

  Future<_NetworkInfo> _loadNetworkInfo(int port) async {
    final hostname = Platform.localHostname;
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );

    final localIps = <String>{};
    final tailscaleIps = <String>{};
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        final value = address.address;
        localIps.add(value);
        if (_isTailscaleIpv4(value)) {
          tailscaleIps.add(value);
        }
      }
    }

    final endpoints = <HostAccessEndpoint>[
      HostAccessEndpoint(label: 'ローカル', url: 'http://127.0.0.1:$port'),
      if (hostname.trim().isNotEmpty)
        HostAccessEndpoint(
          label: 'ホスト名',
          url: 'http://$hostname:$port',
        ),
      ...tailscaleIps.map(
        (ip) => HostAccessEndpoint(label: 'Tailscale', url: 'http://$ip:$port'),
      ),
    ];

    return _NetworkInfo(
      hostname: hostname,
      localIpv4s: localIps.toList(growable: false)..sort(),
      tailscaleIpv4s: tailscaleIps.toList(growable: false)..sort(),
      endpoints: endpoints,
    );
  }

  bool _isTailscaleIpv4(String value) {
    final parts = value.split('.');
    if (parts.length != 4) {
      return false;
    }
    final first = int.tryParse(parts[0]);
    final second = int.tryParse(parts[1]);
    if (first == null || second == null) {
      return false;
    }
    return first == 100 && second >= 64 && second <= 127;
  }

  Future<MetadataConnectionStatus> _checkHealth(MetadataSettings settings) {
    if (settings.isStandaloneMode) {
      return Future.value(MetadataConnectionStatus.localMode());
    }
    return _loopbackClient(settings).checkHealth();
  }

  RemoteTagApiClient _loopbackClient(MetadataSettings settings) {
    return RemoteTagApiClient(
      baseUrl: settings.hostLoopbackApiBaseUrl,
      defaultHeadersProvider: () {
        final token = settings.authToken?.trim();
        if (token == null || token.isEmpty) {
          return const <String, String>{};
        }
        return <String, String>{'Authorization': 'Bearer $token'};
      },
    );
  }

  void _setStatus(HostServerStatus next) {
    _status = next.copyWith(updatedAt: DateTime.now());
    notifyListeners();
  }
}

class _NetworkInfo {
  final String hostname;
  final List<String> localIpv4s;
  final List<String> tailscaleIpv4s;
  final List<HostAccessEndpoint> endpoints;

  const _NetworkInfo({
    required this.hostname,
    required this.localIpv4s,
    required this.tailscaleIpv4s,
    required this.endpoints,
  });
}
