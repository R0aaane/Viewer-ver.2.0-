import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/errors/app_exception.dart';

class XAuthCallbackService {
  const XAuthCallbackService();

  static const MethodChannel _methodChannel = MethodChannel(
    'xviewer/auth_callback',
  );
  static const EventChannel _eventChannel = EventChannel(
    'xviewer/auth_callback/events',
  );

  Future<Uri> waitForCallback(
    String redirectUri, {
    Duration timeout = const Duration(minutes: 3),
  }) async {
    debugPrint(
      '[xviewer][flutter] Waiting for OAuth callback. redirectUri=$redirectUri',
    );
    final pendingUrl = await _consumePendingCallbackUrl();
    final pendingUri = _tryParseMatchingUri(pendingUrl, redirectUri);
    if (pendingUri != null) {
      debugPrint(
        '[xviewer][flutter] Using pending OAuth callback.',
      );
      return pendingUri;
    }

    try {
      debugPrint(
        '[xviewer][flutter] Subscribing to EventChannel for OAuth callback events.',
      );
      return await _eventChannel
          .receiveBroadcastStream()
          .where((event) => event is String)
          .cast<String>()
          .map((url) => _tryParseMatchingUri(url, redirectUri))
          .where((uri) => uri != null)
          .cast<Uri>()
          .timeout(timeout)
          .first;
    } on MissingPluginException catch (error) {
      throw AppException(
        'X OAuth callback handling is not available on this platform.',
        details: error,
      );
    } on TimeoutException catch (error) {
      throw AppException(
        'Timed out waiting for the X OAuth callback.',
        details: error,
      );
    }
  }

  Future<Uri?> consumePendingCallback(String redirectUri) async {
    debugPrint(
      '[xviewer][flutter] Checking for pending OAuth callback. redirectUri=$redirectUri',
    );
    final pendingUrl = await _consumePendingCallbackUrl();
    final pendingUri = _tryParseMatchingUri(pendingUrl, redirectUri);
    if (pendingUri == null) {
      debugPrint('[xviewer][flutter] No pending OAuth callback was available.');
    } else {
      debugPrint(
        '[xviewer][flutter] Consumed pending OAuth callback.',
      );
    }
    return pendingUri;
  }

  Future<String?> _consumePendingCallbackUrl() async {
    try {
      final url = await _methodChannel.invokeMethod<String>(
        'consumePendingCallbackUrl',
      );
      debugPrint('[xviewer][flutter] Pending callback found: ${url != null}');
      return url;
    } on MissingPluginException {
      return null;
    }
  }

  Uri? _tryParseMatchingUri(String? rawUrl, String redirectUri) {
    if ((rawUrl ?? '').isEmpty) {
      return null;
    }

    final actual = Uri.tryParse(rawUrl!);
    final expected = Uri.tryParse(redirectUri);
    if (actual == null || expected == null) {
      debugPrint(
        '[xviewer][flutter] Failed to parse callback URL.',
      );
      return null;
    }

    final sameAuthority =
        actual.scheme == expected.scheme && actual.host == expected.host;
    final samePath = actual.path == expected.path;
    debugPrint(
      '[xviewer][flutter] Callback match: authority=$sameAuthority path=$samePath',
    );
    if (!sameAuthority || !samePath) {
      debugPrint(
        '[xviewer][flutter] Ignored non-matching callback URL.',
      );
      return null;
    }

    debugPrint('[xviewer][flutter] Accepted callback URL.');
    return actual;
  }
}
