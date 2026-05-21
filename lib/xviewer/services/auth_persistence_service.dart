import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/storage_keys.dart';
import '../core/errors/app_exception.dart';
import '../domain/models/auth_session.dart';
import '../domain/models/oauth_token_bundle.dart';
import 'secure_token_storage_service.dart';

class AuthPersistenceService {
  AuthPersistenceService(this._secureTokenStorageService);

  final SecureTokenStorageService _secureTokenStorageService;

  Future<void> saveSession(AuthSession session) async {
    if (!session.hasAccessToken) {
      throw const AppException(
        'Cannot persist an auth session without an access token.',
      );
    }

    debugPrint(
      '[xviewer][flutter] Persisting auth session: key=${StorageKeys.authSession} userId=${session.userId} username=${session.username} hasAccessToken=${session.hasAccessToken} hasRefreshToken=${(session.refreshToken ?? '').isNotEmpty}',
    );
    final prefs = await SharedPreferences.getInstance();
    await _secureTokenStorageService.saveTokens(
      OAuthTokenBundle(
        accessToken: session.accessToken!,
        refreshToken: session.refreshToken,
        expiresAt: session.expiresAt,
      ),
    );
    debugPrint(
      '[xviewer][flutter] Access token saved successfully for userId=${session.userId}',
    );
    debugPrint(
      '[xviewer][flutter] Refresh token saved successfully: hasRefreshToken=${(session.refreshToken ?? '').isNotEmpty}',
    );
    await prefs.setString(
      StorageKeys.authSession,
      jsonEncode(
        session
            .copyWith(
              clearAccessToken: true,
              clearRefreshToken: true,
              clearExpiresAt: true,
            )
            .toJson(),
      ),
    );
    debugPrint(
      '[xviewer][flutter] Auth session metadata saved: key=${StorageKeys.authSession}',
    );
  }

  Future<AuthSession?> getSession() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(StorageKeys.authSession);
    debugPrint(
      '[xviewer][flutter] Reading auth session: key=${StorageKeys.authSession} found=${(raw ?? '').isNotEmpty}',
    );
    if (raw == null || raw.isEmpty) {
      await _secureTokenStorageService.clearTokens();
      return null;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        await clearSession();
        return null;
      }

      final session = AuthSession.fromJson(decoded);
      final tokens = await _secureTokenStorageService.readTokens();
      if (session.userId.isEmpty ||
          session.username.isEmpty ||
          session.displayName.isEmpty ||
          tokens == null ||
          !tokens.hasAccessToken) {
        debugPrint(
          '[xviewer][flutter] Stored auth session was incomplete. Clearing persisted auth state.',
        );
        await clearSession();
        return null;
      }

      final restoredSession = session.copyWith(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        expiresAt: tokens.expiresAt,
      );
      debugPrint(
        '[xviewer][flutter] Restored auth session successfully: userId=${restoredSession.userId} username=${restoredSession.username} hasAccessToken=${restoredSession.hasAccessToken}',
      );
      return restoredSession;
    } on FormatException {
      await clearSession();
      return null;
    }
  }

  Future<void> clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    debugPrint(
      '[xviewer][flutter] Clearing persisted auth session: key=${StorageKeys.authSession}',
    );
    await prefs.remove(StorageKeys.authSession);
    await _secureTokenStorageService.clearTokens();
  }
}
