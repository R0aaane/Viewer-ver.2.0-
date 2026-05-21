import 'login_mode.dart';

class AuthSession {
  const AuthSession({
    required this.userId,
    required this.username,
    required this.displayName,
    required this.loginMode,
    this.accessToken,
    this.refreshToken,
    this.expiresAt,
  });

  final String userId;
  final String username;
  final String displayName;
  final LoginMode loginMode;
  final String? accessToken;
  final String? refreshToken;
  final DateTime? expiresAt;

  bool get hasAccessToken => (accessToken ?? '').isNotEmpty;

  AuthSession copyWith({
    String? userId,
    String? username,
    String? displayName,
    LoginMode? loginMode,
    String? accessToken,
    bool clearAccessToken = false,
    String? refreshToken,
    bool clearRefreshToken = false,
    DateTime? expiresAt,
    bool clearExpiresAt = false,
  }) {
    return AuthSession(
      userId: userId ?? this.userId,
      username: username ?? this.username,
      displayName: displayName ?? this.displayName,
      loginMode: loginMode ?? this.loginMode,
      accessToken: clearAccessToken ? null : (accessToken ?? this.accessToken),
      refreshToken: clearRefreshToken
          ? null
          : (refreshToken ?? this.refreshToken),
      expiresAt: clearExpiresAt ? null : (expiresAt ?? this.expiresAt),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'username': username,
      'displayName': displayName,
      'loginMode': loginMode.name,
      'accessToken': accessToken,
      'refreshToken': refreshToken,
      'expiresAt': expiresAt?.toIso8601String(),
    };
  }

  factory AuthSession.fromJson(Map<String, dynamic> json) {
    return AuthSession(
      userId: json['userId'] as String? ?? '',
      username: json['username'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '',
      loginMode: LoginMode.values.firstWhere(
        (mode) => mode.name == json['loginMode'],
        orElse: () => LoginMode.xOAuth,
      ),
      accessToken: json['accessToken'] as String?,
      refreshToken: json['refreshToken'] as String?,
      expiresAt: json['expiresAt'] == null
          ? null
          : DateTime.tryParse(json['expiresAt'] as String),
    );
  }
}
