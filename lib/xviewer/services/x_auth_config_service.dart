import 'dart:convert';

import 'package:flutter/services.dart';

import '../core/constants/x_auth_constants.dart';

class XAuthConfigService {
  XAuthConfigService({
    String? clientId,
    String? redirectUri,
    this.scopes = XAuthConstants.defaultScopes,
  }) : clientId = clientId ?? _envClientId ?? XAuthConstants.defaultClientId,
       redirectUri =
           redirectUri ?? _envRedirectUri ?? XAuthConstants.defaultRedirectUri;

  static String? _envClientId;
  static String? _envRedirectUri;

  final String clientId;
  final String redirectUri;
  final List<String> scopes;

  bool get isConfigured =>
      clientId.isNotEmpty &&
      clientId != 'TODO_SET_X_CLIENT_ID' &&
      redirectUri.isNotEmpty;

  static Future<void> loadEnvAsset() async {
    try {
      final raw = await rootBundle.loadString('env.json');
      final json = jsonDecode(raw) as Map<String, dynamic>;
      _envClientId = (json['X_CLIENT_ID'] as String?)?.trim();
      _envRedirectUri = (json['X_REDIRECT_URI'] as String?)?.trim();
    } catch (_) {
      _envClientId = null;
      _envRedirectUri = null;
    }
  }
}
