import '../../domain/models/login_mode.dart';

class AppEnvironment {
  const AppEnvironment({
    required this.loginMode,
  });

  final LoginMode loginMode;

  factory AppEnvironment.fromDefines() {
    const loginModeValue = String.fromEnvironment(
      'LOGIN_MODE',
      defaultValue: 'xOAuth',
    );

    return AppEnvironment(
      loginMode: loginModeValue == LoginMode.xOAuth.name
          ? LoginMode.xOAuth
          : LoginMode.xOAuth,
    );
  }
}
