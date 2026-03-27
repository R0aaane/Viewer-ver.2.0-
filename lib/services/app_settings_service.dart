import 'package:shared_preferences/shared_preferences.dart';

import '../models/metadata_settings.dart';

class AppSettingsService {
  static const String _metadataModeKey = 'prefs.metadata.storageMode';
  static const String _metadataApiBaseUrlKey = 'prefs.metadata.remoteApiBaseUrl';
  static const String _metadataAuthTokenKey = 'prefs.metadata.authToken';

  Future<MetadataSettings> loadMetadataSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final modeIndex = prefs.getInt(_metadataModeKey) ?? 0;
    final mode = (modeIndex >= 0 && modeIndex < MetadataStorageMode.values.length)
        ? MetadataStorageMode.values[modeIndex]
        : MetadataStorageMode.local;

    return MetadataSettings(
      storageMode: mode,
      remoteApiBaseUrl: prefs.getString(_metadataApiBaseUrlKey) ?? '',
      authToken: prefs.getString(_metadataAuthTokenKey),
    );
  }

  Future<void> saveMetadataSettings(MetadataSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_metadataModeKey, settings.storageMode.index);
    await prefs.setString(_metadataApiBaseUrlKey, settings.remoteApiBaseUrl);

    final token = settings.authToken?.trim();
    if (token == null || token.isEmpty) {
      await prefs.remove(_metadataAuthTokenKey);
    } else {
      await prefs.setString(_metadataAuthTokenKey, token);
    }
  }
}
