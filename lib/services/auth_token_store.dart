import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AuthTokenStore {
  static String? _browserToken;
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  bool get persistent => !kIsWeb;

  Future<String?> read() async =>
      kIsWeb ? _browserToken : _storage.read(key: 'pdf_viewer.authToken');

  Future<void> write(String? token) async {
    if (kIsWeb) {
      _browserToken = token;
    } else if (token == null || token.isEmpty) {
      await _storage.delete(key: 'pdf_viewer.authToken');
    } else {
      await _storage.write(key: 'pdf_viewer.authToken', value: token);
    }
  }

  static String generate() {
    final random = Random.secure();
    return List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}
