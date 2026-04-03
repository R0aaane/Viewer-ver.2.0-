import 'package:shared_preferences/shared_preferences.dart';

import '../models/metadata_settings.dart';

class AppSettingsService {
  static const String _legacyMetadataModeKey = 'prefs.metadata.storageMode';
  static const String _appModeKey = 'prefs.app.mode';
  static const String _clientApiBaseUrlKey = 'prefs.client.apiBaseUrl';
  static const String _legacyMetadataApiBaseUrlKey =
      'prefs.metadata.remoteApiBaseUrl';
  static const String _metadataAuthTokenKey = 'prefs.metadata.authToken';
  static const String _hostPortKey = 'prefs.host.port';
  static const String _hostAutoStartKey = 'prefs.host.autoStartServer';
  static const String _hostLibraryPathKey = 'prefs.host.libraryPath';

  Future<MetadataSettings> loadMetadataSettings() async {
    final prefs = await SharedPreferences.getInstance();

    final mode = _loadAppMode(prefs);
    final clientApiBaseUrl =
        prefs.getString(_clientApiBaseUrlKey) ??
        prefs.getString(_legacyMetadataApiBaseUrlKey) ??
        '';
    final hostPort = prefs.getInt(_hostPortKey) ?? 8080;

    return MetadataSettings(
      appMode: mode,
      clientApiBaseUrl: clientApiBaseUrl,
      hostPort: hostPort < 1 ? 8080 : hostPort,
      authToken: prefs.getString(_metadataAuthTokenKey),
      autoStartHostServer: prefs.getBool(_hostAutoStartKey) ?? false,
      hostLibraryPath: prefs.getString(_hostLibraryPathKey) ?? '',
    );
  }

  AppMode _loadAppMode(SharedPreferences prefs) {
    final storedIndex = prefs.getInt(_appModeKey);
    if (storedIndex != null &&
        storedIndex >= 0 &&
        storedIndex < AppMode.values.length) {
      return AppMode.values[storedIndex];
    }

    final legacyModeIndex = prefs.getInt(_legacyMetadataModeKey) ?? 0;
    final legacyMode =
        (legacyModeIndex >= 0 &&
            legacyModeIndex < MetadataStorageMode.values.length)
        ? MetadataStorageMode.values[legacyModeIndex]
        : MetadataStorageMode.local;
    return legacyMode == MetadataStorageMode.remote
        ? AppMode.client
        : AppMode.standalone;
  }

  Future<void> saveMetadataSettings(MetadataSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_appModeKey, settings.appMode.index);
    await prefs.setInt(_legacyMetadataModeKey, settings.storageMode.index);
    await prefs.setString(_clientApiBaseUrlKey, settings.clientApiBaseUrl);
    await prefs.setString(
      _legacyMetadataApiBaseUrlKey,
      settings.clientApiBaseUrl,
    );
    await prefs.setInt(_hostPortKey, settings.hostPort);
    await prefs.setBool(_hostAutoStartKey, settings.autoStartHostServer);
    final libraryPath = settings.hostLibraryPath.trim();
    if (libraryPath.isEmpty) {
      await prefs.remove(_hostLibraryPathKey);
    } else {
      await prefs.setString(_hostLibraryPathKey, libraryPath);
    }

    final token = settings.authToken?.trim();
    if (token == null || token.isEmpty) {
      await prefs.remove(_metadataAuthTokenKey);
    } else {
      await prefs.setString(_metadataAuthTokenKey, token);
    }
  }
}
