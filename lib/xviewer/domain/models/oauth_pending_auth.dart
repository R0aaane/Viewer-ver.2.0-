class OAuthPendingAuth {
  const OAuthPendingAuth({
    required this.state,
    required this.codeVerifier,
    required this.redirectUri,
    required this.createdAt,
  });

  final String state;
  final String codeVerifier;
  final String redirectUri;
  final DateTime createdAt;

  bool get hasRequiredValues =>
      state.isNotEmpty && codeVerifier.isNotEmpty && redirectUri.isNotEmpty;

  Map<String, dynamic> toJson() {
    return {
      'state': state,
      'codeVerifier': codeVerifier,
      'redirectUri': redirectUri,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory OAuthPendingAuth.fromJson(Map<String, dynamic> json) {
    return OAuthPendingAuth(
      state: json['state'] as String? ?? '',
      codeVerifier: json['codeVerifier'] as String? ?? '',
      redirectUri: json['redirectUri'] as String? ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}
