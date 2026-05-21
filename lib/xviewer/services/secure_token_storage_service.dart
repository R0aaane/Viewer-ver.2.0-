import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/constants/storage_keys.dart';
import '../domain/models/oauth_token_bundle.dart';

class SecureTokenStorageService {
  const SecureTokenStorageService({
    FlutterSecureStorage? storage,
  }) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  Future<void> saveTokens(OAuthTokenBundle tokens) async {
    await _storage.write(
      key: StorageKeys.oauthTokens,
      value: jsonEncode(tokens.toJson()),
    );
    debugPrint(
      '[xviewer][flutter] Token storage write complete: key=${StorageKeys.oauthTokens} accessTokenSaved=${tokens.accessToken.isNotEmpty} refreshTokenSaved=${(tokens.refreshToken ?? '').isNotEmpty}',
    );
  }

  Future<OAuthTokenBundle?> readTokens() async {
    final raw = await _storage.read(key: StorageKeys.oauthTokens);
    debugPrint(
      '[xviewer][flutter] Token storage read: key=${StorageKeys.oauthTokens} found=${(raw ?? '').isNotEmpty}',
    );
    if (raw == null || raw.isEmpty) {
      return null;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        await clearTokens();
        return null;
      }
      final bundle = OAuthTokenBundle.fromJson(decoded);
      if (!bundle.hasAccessToken) {
        await clearTokens();
        return null;
      }
      return bundle;
    } on FormatException {
      await clearTokens();
      return null;
    }
  }

  Future<void> clearTokens() {
    debugPrint(
      '[xviewer][flutter] Token storage clear: key=${StorageKeys.oauthTokens}',
    );
    return _storage.delete(key: StorageKeys.oauthTokens);
  }
}
