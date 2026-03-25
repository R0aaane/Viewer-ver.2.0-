import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

class ExternalSharePayload {
  final List<String> rawItems;
  final bool hasUnsupportedPayload;
  final String? action;
  final String? mimeType;

  const ExternalSharePayload({
    required this.rawItems,
    required this.hasUnsupportedPayload,
    this.action,
    this.mimeType,
  });

  bool get hasFiles => rawItems.isNotEmpty;
  bool get isEmpty => rawItems.isEmpty && !hasUnsupportedPayload;

  factory ExternalSharePayload.fromMap(Map<dynamic, dynamic> map) {
    final rawItems = (map['rawItems'] as List<dynamic>? ?? const [])
        .map((value) => value.toString())
        .where((value) => value.trim().isNotEmpty)
        .toList(growable: false);

    return ExternalSharePayload(
      rawItems: rawItems,
      hasUnsupportedPayload: map['hasUnsupportedPayload'] == true,
      action: map['action']?.toString(),
      mimeType: map['mimeType']?.toString(),
    );
  }
}

class ExternalShareService {
  static const MethodChannel _methodChannel =
      MethodChannel('pdf_viewer/external_share');
  static const EventChannel _eventChannel =
      EventChannel('pdf_viewer/external_share/events');

  Stream<ExternalSharePayload>? _payloads;

  Stream<ExternalSharePayload> get payloads {
    if (!Platform.isAndroid) {
      return const Stream<ExternalSharePayload>.empty();
    }

    _payloads ??= _eventChannel.receiveBroadcastStream().map((event) {
      final map = (event as Map<dynamic, dynamic>? ?? const {});
      return ExternalSharePayload.fromMap(map);
    });
    return _payloads!;
  }

  Future<ExternalSharePayload?> takeInitialPayload() async {
    if (!Platform.isAndroid) return null;

    try {
      final raw = await _methodChannel.invokeMethod<dynamic>(
        'getInitialSharedPayload',
      );
      await _methodChannel.invokeMethod<void>('clearInitialSharedPayload');

      if (raw is! Map<dynamic, dynamic>) return null;
      final payload = ExternalSharePayload.fromMap(raw);
      return payload.isEmpty ? null : payload;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
