import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pdf_viewer/services/app_settings_service.dart';
import 'package:pdf_viewer/services/auth_token_store.dart';
import 'package:pdf_viewer/models/metadata_settings.dart';

class _Vault extends AuthTokenStore {
  String? token;
  bool fail = false;
  bool durable = true;
  @override
  bool get persistent => durable;
  @override
  Future<String?> read() async => token;
  @override
  Future<void> write(String? value) async {
    if (fail) throw StateError('vault unavailable');
    token = value;
  }
}

void main() {
  test(
    'native legacy token migrates only after secure storage succeeds',
    () async {
      SharedPreferences.setMockInitialValues({
        'prefs.metadata.authToken': 'legacy-secret',
      });
      final vault = _Vault();
      final service = AppSettingsService(tokenStore: vault);
      final settings = await service.loadMetadataSettings();
      expect(settings.authToken, 'legacy-secret');
      expect(vault.token, 'legacy-secret');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('prefs.metadata.authToken'), isFalse);
      expect((await service.loadMetadataSettings()).authToken, 'legacy-secret');
      vault.fail = true;
      await expectLater(
        service.saveMetadataSettings(
          settings.copyWith(authToken: 'new-secret'),
        ),
        throwsStateError,
      );
      expect(vault.token, 'legacy-secret');
      expect(prefs.containsKey('prefs.metadata.authToken'), isFalse);
      vault.fail = false;
      await service.saveMetadataSettings(
        settings.copyWith(clearAuthToken: true),
      );
      expect(vault.token, isNull);
    },
  );

  test(
    'browser discards old persisted tokens and keeps new tokens in session memory',
    () async {
      SharedPreferences.setMockInitialValues({
        'prefs.metadata.authToken': 'old-browser-secret',
      });
      final vault = _Vault()..durable = false;
      final service = AppSettingsService(tokenStore: vault);
      expect((await service.loadMetadataSettings()).authToken, isNull);
      await service.saveMetadataSettings(
        const MetadataSettings(authToken: 'session-secret'),
      );
      expect(
        (await service.loadMetadataSettings()).authToken,
        'session-secret',
      );
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getKeys().any((key) => prefs.get(key) == 'session-secret'),
        isFalse,
      );
      expect(prefs.containsKey('prefs.metadata.authToken'), isFalse);
      final restarted = AppSettingsService(
        tokenStore: _Vault()..durable = false,
      );
      expect((await restarted.loadMetadataSettings()).authToken, isNull);
    },
  );
}
