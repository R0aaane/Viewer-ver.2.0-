import 'x_api_constants.dart';

abstract final class XAuthConstants {
  static const authorizationHost = 'x.com';
  static const authorizationPath = '/i/oauth2/authorize';
  static const tokenEndpoint = '${XApiConstants.primaryV2BaseUrl}/oauth2/token';
  static const fallbackTokenEndpoint =
      '${XApiConstants.fallbackV2BaseUrl}/oauth2/token';
  static const currentUserEndpoint =
      '${XApiConstants.primaryV2BaseUrl}/users/me';
  static const fallbackCurrentUserEndpoint =
      '${XApiConstants.fallbackV2BaseUrl}/users/me';
  static const defaultClientId = String.fromEnvironment(
    'X_CLIENT_ID',
    defaultValue: 'TODO_SET_X_CLIENT_ID',
  );
  static const callbackScheme = 'xviewer';
  static const callbackHost = 'auth';
  static const callbackPath = '/callback';
  static const defaultRedirectUri =
      '$callbackScheme://$callbackHost$callbackPath';
  static const callbackUriPrefix = defaultRedirectUri;
  static const defaultScopes = <String>[
    'tweet.read',
    'users.read',
    'offline.access',
  ];
  static const codeChallengeMethod = 'S256';
  static const responseType = 'code';
  static const callbackTimeout = Duration(minutes: 3);
}
