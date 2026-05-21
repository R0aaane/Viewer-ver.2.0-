import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../core/constants/x_auth_constants.dart';
import '../core/errors/app_exception.dart';
import '../data/datasources/x_auth_client.dart';
import '../domain/models/auth_session.dart';
import '../domain/models/login_mode.dart';
import '../domain/models/oauth_pending_auth.dart';
import 'link_launcher_service.dart';
import 'oauth_pending_auth_storage_service.dart';
import 'x_auth_callback_service.dart';
import 'x_auth_config_service.dart';

class XOAuthService {
  XOAuthService({
    required XAuthConfigService config,
    required XAuthClient authClient,
    required LinkLauncherService linkLauncherService,
    required XAuthCallbackService callbackService,
    required OAuthPendingAuthStorageService pendingAuthStorageService,
  }) : _config = config,
       _authClient = authClient,
       _linkLauncherService = linkLauncherService,
       _callbackService = callbackService,
       _pendingAuthStorageService = pendingAuthStorageService;

  final XAuthConfigService _config;
  final XAuthClient _authClient;
  final LinkLauncherService _linkLauncherService;
  final XAuthCallbackService _callbackService;
  final OAuthPendingAuthStorageService _pendingAuthStorageService;

  Future<AuthSession> signIn() async {
    if (!_config.isConfigured) {
      throw const AppException(
        'X OAuth is not configured. Set X_CLIENT_ID and X_REDIRECT_URI.',
      );
    }

    final state = _randomString();
    final codeVerifier = _randomString(length: 96);
    final codeChallenge = _createCodeChallenge(codeVerifier);
    final pendingAuth = OAuthPendingAuth(
      state: state,
      codeVerifier: codeVerifier,
      redirectUri: _config.redirectUri,
      createdAt: DateTime.now(),
    );

    await _pendingAuthStorageService.save(pendingAuth);

    final callbackFuture = _callbackService.waitForCallback(
      _config.redirectUri,
      timeout: XAuthConstants.callbackTimeout,
    );
    final authorizeUri = _buildAuthorizationUri(
      state: state,
      codeChallenge: codeChallenge,
    );
    _logAuthorizationRequest(authorizeUri);
    _validateAuthorizationUri(authorizeUri);
    debugPrint(
      '[xviewer][flutter] Starting OAuth authorization. authorizeUrl=$authorizeUri',
    );
    debugPrint(
      '[xviewer][flutter] [OAuth] redirectUri=${_config.redirectUri}',
    );

    await _linkLauncherService.openExternal(
      authorizeUri.toString(),
      debugLabel: 'OAuth authorize URL',
      failureMessage:
          'Could not open the X authorization page in an external browser.',
    );

    final callbackUri = await callbackFuture;
    return handleOAuthCallback(callbackUri);
  }

  Future<AuthSession?> restorePendingSignInIfAvailable() async {
    final pendingAuth = await _pendingAuthStorageService.read();
    if (pendingAuth == null) {
      debugPrint(
        '[xviewer][flutter] No pending OAuth request found during startup restore.',
      );
      return null;
    }

    final callbackUri = await _callbackService.consumePendingCallback(
      _config.redirectUri,
    );
    if (callbackUri == null) {
      debugPrint(
        '[xviewer][flutter] Pending OAuth request exists, but no callback URI was available yet.',
      );
      return null;
    }

    debugPrint(
      '[xviewer][flutter] Restoring pending OAuth sign-in from callback URI.',
    );
    return handleOAuthCallback(callbackUri);
  }

  Future<AuthSession> handleOAuthCallback(Uri callbackUri) async {
    debugPrint('[xviewer][flutter] OAuth callback received: $callbackUri');
    final pendingAuth = await _pendingAuthStorageService.read();
    if (pendingAuth == null) {
      debugPrint(
        '[xviewer][flutter] [OAuth] callback failed: no saved pending OAuth request was found.',
      );
      throw const AppException(
        'OAuth callback could not be completed because no pending login request was found.',
      );
    }

    final error = callbackUri.queryParameters['error'];
    final returnedState = callbackUri.queryParameters['state'] ?? '';
    final code = callbackUri.queryParameters['code'] ?? '';
    final codeVerifier = pendingAuth.codeVerifier;
    _logCallbackDetails(
      callbackUri: callbackUri,
      expectedState: pendingAuth.state,
      actualState: returnedState,
      code: code,
      error: error,
      hasCodeVerifier: codeVerifier.isNotEmpty,
    );

    if ((error ?? '').isNotEmpty) {
      await _pendingAuthStorageService.clear();
      throw AppException(
        'X authorization was denied: $error',
        details: callbackUri.queryParameters['error_description'],
      );
    }

    debugPrint(
      '[xviewer][flutter] OAuth callback parsed: scheme=${callbackUri.scheme}, host=${callbackUri.host}, path=${callbackUri.path}, code=$code, state=$returnedState, error=$error',
    );
    if (returnedState != pendingAuth.state) {
      debugPrint(
        '[xviewer][flutter] [OAuth] state mismatch detected. expectedState=${pendingAuth.state} actualState=$returnedState',
      );
      await _pendingAuthStorageService.clear();
      throw AppException(
        'X OAuth state verification failed.',
        details: callbackUri.toString(),
      );
    }

    if (code.isEmpty) {
      debugPrint(
        '[xviewer][flutter] [OAuth] callback failed: authorization code was missing.',
      );
      await _pendingAuthStorageService.clear();
      throw AppException(
        'X OAuth callback did not contain an authorization code.',
        details: callbackUri.toString(),
      );
    }

    if (codeVerifier.isEmpty) {
      debugPrint(
        '[xviewer][flutter] [OAuth] callback failed: saved code_verifier was missing.',
      );
      await _pendingAuthStorageService.clear();
      throw const AppException(
        'X OAuth callback could not be completed because the saved code verifier was missing.',
      );
    }

    debugPrint(
      '[xviewer][flutter] [OAuth] token exchange starting: redirectUri=${pendingAuth.redirectUri} expectedState=${pendingAuth.state} actualState=$returnedState hasCode=${code.isNotEmpty} hasCodeVerifier=${codeVerifier.isNotEmpty}',
    );

    try {
      final token = await _authClient.exchangeCodeForToken(
        clientId: _config.clientId,
        code: code,
        codeVerifier: codeVerifier,
        redirectUri: pendingAuth.redirectUri,
      );
      debugPrint(
        '[xviewer][flutter] [OAuth] token exchange succeeded: hasAccessToken=${token.accessToken.isNotEmpty} hasRefreshToken=${(token.refreshToken ?? '').isNotEmpty}',
      );

      final user = await _authClient.fetchCurrentUser(
        accessToken: token.accessToken,
      );
      await _pendingAuthStorageService.clear();

      return AuthSession(
        userId: user.id,
        username: user.username,
        displayName: user.name,
        loginMode: LoginMode.xOAuth,
        accessToken: token.accessToken,
        refreshToken: token.refreshToken,
        expiresAt: token.expiresIn == null
            ? null
            : DateTime.now().add(Duration(seconds: token.expiresIn!)),
      );
    } catch (error) {
      debugPrint('[xviewer][flutter] [OAuth] token exchange failed: $error');
      await _pendingAuthStorageService.clear();
      rethrow;
    }
  }

  Uri _buildAuthorizationUri({
    required String state,
    required String codeChallenge,
  }) {
    return Uri.https(
      XAuthConstants.authorizationHost,
      XAuthConstants.authorizationPath,
      <String, String>{
        'client_id': _config.clientId,
        'redirect_uri': _config.redirectUri,
        'response_type': XAuthConstants.responseType,
        'scope': _config.scopes.join(' '),
        'state': state,
        'code_challenge': codeChallenge,
        'code_challenge_method': XAuthConstants.codeChallengeMethod,
      },
    );
  }

  void _logAuthorizationRequest(Uri authorizeUri) {
    debugPrint('[xviewer][flutter] [OAuth] authorize url=$authorizeUri');
    debugPrint('[xviewer][flutter] [OAuth] redirectUri=${_config.redirectUri}');
    debugPrint(
      '[xviewer][flutter] [OAuth] authorize params: client_id=${authorizeUri.queryParameters['client_id']} redirect_uri=${authorizeUri.queryParameters['redirect_uri']} response_type=${authorizeUri.queryParameters['response_type']} scope=${authorizeUri.queryParameters['scope']} state=${authorizeUri.queryParameters['state']} code_challenge=${authorizeUri.queryParameters['code_challenge']} code_challenge_method=${authorizeUri.queryParameters['code_challenge_method']}',
    );
  }

  void _validateAuthorizationUri(Uri authorizeUri) {
    final query = authorizeUri.queryParameters;
    final requiredKeys = <String, String>{
      'client_id': _config.clientId,
      'redirect_uri': _config.redirectUri,
      'response_type': XAuthConstants.responseType,
      'scope': _config.scopes.join(' '),
      'state': query['state'] ?? '',
      'code_challenge': query['code_challenge'] ?? '',
      'code_challenge_method': XAuthConstants.codeChallengeMethod,
    };

    for (final entry in requiredKeys.entries) {
      final value = query[entry.key] ?? '';
      final isMissing = value.isEmpty;
      final isMismatch = !isMissing &&
          entry.value.isNotEmpty &&
          value != entry.value &&
          entry.key != 'state' &&
          entry.key != 'code_challenge';
      debugPrint(
        '[xviewer][flutter] [OAuth] param check: key=${entry.key} present=${!isMissing} expected=${entry.value} actual=$value',
      );
      if (isMissing || isMismatch) {
        throw AppException(
          'X OAuth authorization URL is invalid.',
          details:
              'key=${entry.key} expected=${entry.value} actual=$value authorizeUrl=$authorizeUri',
        );
      }
    }
  }

  void _logCallbackDetails({
    required Uri callbackUri,
    required String expectedState,
    required String actualState,
    required String code,
    required String? error,
    required bool hasCodeVerifier,
  }) {
    debugPrint('[xviewer][flutter] [OAuth] callback uri=$callbackUri');
    debugPrint(
      '[xviewer][flutter] [OAuth] callback validation: returnedState=$actualState expectedState=$expectedState stateMatches=${expectedState == actualState} hasCode=${code.isNotEmpty} hasCodeVerifier=$hasCodeVerifier hasError=${(error ?? '').isNotEmpty}',
    );
  }

  String _createCodeChallenge(String codeVerifier) {
    final digest = sha256.convert(utf8.encode(codeVerifier));
    return base64UrlEncode(digest.bytes).replaceAll('=', '');
  }

  String _randomString({int length = 64}) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final random = Random.secure();
    return List.generate(
      length,
      (_) => chars[random.nextInt(chars.length)],
    ).join();
  }
}
