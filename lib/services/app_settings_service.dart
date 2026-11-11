import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/metadata_settings.dart';
import 'auth_token_store.dart';

class AppSettingsService {
  final AuthTokenStore _tokenStore;
  AppSettingsService({AuthTokenStore? tokenStore})
    : _tokenStore = tokenStore ?? AuthTokenStore();
  static const _secureTokenPresentKey = 'prefs.metadata.hasSecureToken';
  static const String _legacyMetadataModeKey = 'prefs.metadata.storageMode';
  static const String _appModeKey = 'prefs.app.mode';
  static const String _clientApiBaseUrlKey = 'prefs.client.apiBaseUrl';
  static const String _legacyMetadataApiBaseUrlKey =
      'prefs.metadata.remoteApiBaseUrl';
  static const String _metadataAuthTokenKey = 'prefs.metadata.authToken';
  static const String _hostPortKey = 'prefs.host.port';
  static const String _hostAutoStartKey = 'prefs.host.autoStartServer';
  static const String _hostLibraryPathKey = 'prefs.host.libraryPath';
  MetadataSettings? _memorySettings;

  Future<MetadataSettings> loadMetadataSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final mode = _loadAppMode(prefs);
      final clientApiBaseUrl =
          prefs.getString(_clientApiBaseUrlKey) ??
          prefs.getString(_legacyMetadataApiBaseUrlKey) ??
          '';
      final hostPort = prefs.getInt(_hostPortKey) ?? 8090;
      final legacyToken = prefs.getString(_metadataAuthTokenKey)?.trim();
      String? token;
      if (!_tokenStore.persistent ||
          prefs.getBool(_secureTokenPresentKey) == true ||
          legacyToken?.isNotEmpty == true) {
        token = await _tokenStore.read();
      }
      if (_tokenStore.persistent &&
          token == null &&
          legacyToken?.isNotEmpty == true) {
        await _tokenStore.write(legacyToken);
        token = legacyToken;
        if (!await prefs.setBool(_secureTokenPresentKey, true)) {
          throw StateError('Cannot persist the secure credential marker');
        }
      }
      if (prefs.containsKey(_metadataAuthTokenKey) &&
          !await prefs.remove(_metadataAuthTokenKey)) {
        throw StateError('Cannot remove the legacy credential');
      }
      final settings = MetadataSettings(
        appMode: mode,
        clientApiBaseUrl: clientApiBaseUrl,
        hostPort: hostPort < 1 ? 8090 : hostPort,
        authToken: token,
        autoStartHostServer: prefs.getBool(_hostAutoStartKey) ?? false,
        hostLibraryPath: prefs.getString(_hostLibraryPathKey) ?? '',
      );
      _memorySettings = settings;
      return settings;
    } catch (error, stackTrace) {
      debugPrint('[AppSettingsService] Failed to load settings: $error');
      debugPrintStack(
        label: '[AppSettingsService] loadMetadataSettings',
        stackTrace: stackTrace,
      );
      return _memorySettings ?? const MetadataSettings();
    }
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
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = settings.authToken?.trim();
      await _tokenStore.write(token == null || token.isEmpty ? null : token);
      await prefs.setBool(
        _secureTokenPresentKey,
        _tokenStore.persistent && token?.isNotEmpty == true,
      );
      if (prefs.containsKey(_metadataAuthTokenKey) &&
          !await prefs.remove(_metadataAuthTokenKey)) {
        throw StateError('Cannot remove the legacy credential');
      }
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

      _memorySettings = settings;
    } catch (error, stackTrace) {
      debugPrint('[AppSettingsService] Failed to save settings: $error');
      debugPrintStack(
        label: '[AppSettingsService] saveMetadataSettings',
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }
}
