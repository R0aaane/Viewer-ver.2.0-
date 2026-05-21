import 'app_user.dart';
import 'auth_session.dart';
import 'login_mode.dart';

class AuthState {
  const AuthState({
    required this.user,
    required this.session,
    required this.availableLoginMode,
  });

  final AppUser? user;
  final AuthSession? session;
  final LoginMode availableLoginMode;

  bool get isAuthenticated =>
      user != null && session != null && session!.hasAccessToken;

  String get loginModeLabel => 'X OAuth 2.0 PKCE';
}
