import '../models/app_user.dart';
import '../models/auth_session.dart';
import '../models/login_mode.dart';

abstract interface class AuthRepository {
  Future<AuthSession?> getCurrentSession();
  Future<AuthSession?> restorePendingSession();
  Future<AppUser?> getCurrentUser();
  LoginMode get loginMode;
  Future<AppUser> signIn();
  Future<void> signOut();
}
