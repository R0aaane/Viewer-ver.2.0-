import 'app_exception.dart';
import 'x_api_exception.dart';

String formatErrorMessage(Object error) {
  if (error is XApiException) {
    switch (error.statusCode) {
      case 401:
        return 'X authentication failed. Please sign in again.';
      case 403:
        return 'X API access was denied. Check your app plan, scopes, billing, and credit balance in the Developer Console.';
      case 429:
        return 'X API rate limit exceeded. Please wait and try again.';
      case 503:
        return '\u0058\u5074\u306e\u4e00\u6642\u969c\u5bb3\u306e\u53ef\u80fd\u6027\u304c\u3042\u308a\u307e\u3059\u3002\u6642\u9593\u3092\u7f6e\u3044\u3066\u518d\u8a66\u884c\u3057\u3066\u304f\u3060\u3055\u3044';
      default:
        return error.message;
    }
  }

  if (error is AppException) {
    return error.message;
  }

  return error.toString();
}
