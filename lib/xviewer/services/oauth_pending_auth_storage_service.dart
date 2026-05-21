import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/storage_keys.dart';
import '../domain/models/oauth_pending_auth.dart';

class OAuthPendingAuthStorageService {
  const OAuthPendingAuthStorageService();

  Future<void> save(OAuthPendingAuth pendingAuth) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      StorageKeys.oauthPendingAuth,
      jsonEncode(pendingAuth.toJson()),
    );
    debugPrint(
      '[xviewer][flutter] Saved pending OAuth request: key=${StorageKeys.oauthPendingAuth} state=${pendingAuth.state} hasCodeVerifier=${pendingAuth.codeVerifier.isNotEmpty} redirectUri=${pendingAuth.redirectUri}',
    );
  }

  Future<OAuthPendingAuth?> read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(StorageKeys.oauthPendingAuth);
    debugPrint(
      '[xviewer][flutter] Reading pending OAuth request: key=${StorageKeys.oauthPendingAuth} found=${(raw ?? '').isNotEmpty}',
    );
    if (raw == null || raw.isEmpty) {
      return null;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        await clear();
        return null;
      }
      final pendingAuth = OAuthPendingAuth.fromJson(decoded);
      if (!pendingAuth.hasRequiredValues) {
        await clear();
        return null;
      }
      return pendingAuth;
    } on FormatException {
      await clear();
      return null;
    }
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(StorageKeys.oauthPendingAuth);
    debugPrint(
      '[xviewer][flutter] Cleared pending OAuth request: key=${StorageKeys.oauthPendingAuth}',
    );
  }
}
