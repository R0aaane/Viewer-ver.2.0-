enum MetadataStorageMode {
  local,
  remote,
}

class MetadataSettings {
  final MetadataStorageMode storageMode;
  final String remoteApiBaseUrl;
  final String? authToken;

  const MetadataSettings({
    this.storageMode = MetadataStorageMode.local,
    this.remoteApiBaseUrl = '',
    this.authToken,
  });

  bool get isRemote => storageMode == MetadataStorageMode.remote;

  MetadataSettings copyWith({
    MetadataStorageMode? storageMode,
    String? remoteApiBaseUrl,
    String? authToken,
    bool clearAuthToken = false,
  }) {
    return MetadataSettings(
      storageMode: storageMode ?? this.storageMode,
      remoteApiBaseUrl: remoteApiBaseUrl ?? this.remoteApiBaseUrl,
      authToken: clearAuthToken ? null : (authToken ?? this.authToken),
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
      message: '未確認',
      checkedAt: DateTime.now(),
    );
  }

  factory MetadataConnectionStatus.localMode() {
    return MetadataConnectionStatus(
      state: MetadataConnectionState.localMode,
      message: 'ローカルモードでは接続確認は不要です',
      checkedAt: DateTime.now(),
    );
  }
}
