import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/errors/app_exception.dart';

class LinkLauncherService {
  Future<void> openExternal(
    String url, {
    String debugLabel = 'external URL',
    String failureMessage = 'Could not open external URL',
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      throw const AppException('Invalid URL format');
    }

    debugPrint(
      '[xviewer][flutter] Opening $debugLabel with LaunchMode.externalApplication: $url',
    );
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      debugPrint(
        '[xviewer][flutter] launchUrl externalApplication result: launched=$launched url=$url',
      );
      if (launched) {
        return;
      }

      debugPrint(
        '[xviewer][flutter] External browser launch returned false. Retrying with LaunchMode.inAppBrowserView: $url',
      );
      final fallbackLaunched = await launchUrl(
        uri,
        mode: LaunchMode.inAppBrowserView,
      );
      debugPrint(
        '[xviewer][flutter] launchUrl inAppBrowserView result: launched=$fallbackLaunched url=$url',
      );
      if (!fallbackLaunched) {
        throw AppException(failureMessage, details: url);
      }
    } catch (error) {
      debugPrint(
        '[xviewer][flutter] Failed to open $debugLabel: errorType=${error.runtimeType} error=$error url=$url',
      );
      rethrow;
    }
  }
}
