enum AppMode {
  standalone,
  host,
  client,
}

enum MetadataStorageMode {
  local,
  remote,
}

class MetadataSettings {
  final AppMode appMode;
  final String clientApiBaseUrl;
  final int hostPort;
  final String? authToken;
  final bool autoStartHostServer;
  final String hostLibraryPath;

  const MetadataSettings({
    this.appMode = AppMode.standalone,
    this.clientApiBaseUrl = '',
    this.hostPort = 8090,
    this.authToken,
    this.autoStartHostServer = false,
    this.hostLibraryPath = '',
  });

  bool get isStandaloneMode => appMode == AppMode.standalone;
  bool get isHostMode => appMode == AppMode.host;
  bool get isClientMode => appMode == AppMode.client;

  bool get isRemote => isClientMode;
  bool get usesRemoteRepository => isClientMode;
  bool get shouldMirrorMetadataToHostApi => isHostMode;

  MetadataStorageMode get storageMode =>
      isClientMode ? MetadataStorageMode.remote : MetadataStorageMode.local;

  String get remoteApiBaseUrl => clientApiBaseUrl;

  String get hostLoopbackApiBaseUrl => 'http://127.0.0.1:$hostPort';

  MetadataSettings copyWith({
    AppMode? appMode,
    MetadataStorageMode? storageMode,
    String? clientApiBaseUrl,
    String? remoteApiBaseUrl,
    int? hostPort,
    String? authToken,
    bool clearAuthToken = false,
    bool? autoStartHostServer,
    String? hostLibraryPath,
  }) {
    final resolvedAppMode = appMode ??
        (storageMode == null
            ? this.appMode
            : (storageMode == MetadataStorageMode.remote
                  ? AppMode.client
                  : AppMode.standalone));

    return MetadataSettings(
      appMode: resolvedAppMode,
      clientApiBaseUrl:
          clientApiBaseUrl ?? remoteApiBaseUrl ?? this.clientApiBaseUrl,
      hostPort: hostPort ?? this.hostPort,
      authToken: clearAuthToken ? null : (authToken ?? this.authToken),
      autoStartHostServer: autoStartHostServer ?? this.autoStartHostServer,
      hostLibraryPath: hostLibraryPath ?? this.hostLibraryPath,
    );
  }
}

enum MetadataConnectionState {
  unknown,
  checking,
  connected,
  disconnected,
  localMode,
}

class MetadataConnectionStatus {
  final MetadataConnectionState state;
  final String message;
  final DateTime checkedAt;

  const MetadataConnectionStatus({
    required this.state,
    required this.message,
    required this.checkedAt,
  });

  factory MetadataConnectionStatus.unknown() {
    return MetadataConnectionStatus(
      state: MetadataConnectionState.unknown,
      message: 'まだ接続確認をしていません',
      checkedAt: DateTime.now(),
    );
  }

  factory MetadataConnectionStatus.localMode() {
    return MetadataConnectionStatus(
      state: MetadataConnectionState.localMode,
      message: 'スタンドアロンモードではローカルのメタデータを使用します',
      checkedAt: DateTime.now(),
    );
  }
}
