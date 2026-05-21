import '../../domain/models/app_user.dart';
import '../../domain/models/auth_session.dart';
import '../../domain/models/login_mode.dart';
import '../../domain/repositories/auth_repository.dart';
import '../../services/auth_persistence_service.dart';
import '../../services/x_oauth_service.dart';

class AuthRepositoryImpl implements AuthRepository {
  AuthRepositoryImpl(
    this._persistenceService,
    this._xOAuthService, {
    this.mode = LoginMode.xOAuth,
  });

  final AuthPersistenceService _persistenceService;
  final XOAuthService? _xOAuthService;
  final LoginMode mode;

  @override
  LoginMode get loginMode => mode;

  @override
  Future<AuthSession?> getCurrentSession() {
    return _persistenceService.getSession();
  }

  @override
  Future<AuthSession?> restorePendingSession() async {
    final service = _xOAuthService;
    if (service == null) {
      return null;
    }

    final session = await service.restorePendingSignInIfAvailable();
    if (session == null) {
      return null;
    }

    await _persistenceService.saveSession(session);
    return session;
  }

  @override
  Future<AppUser?> getCurrentUser() async {
    final session = await _persistenceService.getSession();
    if (session == null) {
      return null;
    }

    return AppUser(
      id: session.userId,
      name: session.displayName,
      username: session.username,
    );
  }

  @override
  Future<AppUser> signIn() async {
    final service = _xOAuthService;
    if (service == null) {
      throw StateError('X OAuth service was not configured.');
    }

    final session = await service.signIn();
    await _persistenceService.saveSession(session);
    return AppUser(
      id: session.userId,
      name: session.displayName,
      username: session.username,
    );
  }

  @override
  Future<void> signOut() {
    return _persistenceService.clearSession();
  }
}
