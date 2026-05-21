import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/storage_keys.dart';

class CreatorDisplayNameService {
  CreatorDisplayNameService(this._dio);

  final Dio _dio;

  Future<Map<String, String>> getAllDisplayNames() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(StorageKeys.creatorDisplayNameOverrides);
    if (raw == null || raw.isEmpty) {
      return const <String, String>{};
    }

    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      return const <String, String>{};
    }

    return decoded.map((key, value) {
      return MapEntry(_normalizeUsername('$key'), '$value'.trim());
    })..removeWhere((key, value) => key.isEmpty || value.isEmpty);
  }

  Future<String?> findLocalDisplayName(String authorUsername) async {
    final names = await getAllDisplayNames();
    final value = names[_normalizeUsername(authorUsername)]?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  Future<void> saveDisplayName({
    required String authorUsername,
    required String displayName,
  }) async {
    final username = _normalizeUsername(authorUsername);
    final name = displayName.trim();
    if (username.isEmpty || name.isEmpty) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final names = Map<String, String>.from(await getAllDisplayNames());
    names[username] = name;
    await prefs.setString(
      StorageKeys.creatorDisplayNameOverrides,
      jsonEncode(names),
    );
  }

  Future<List<String>> searchDisplayNameCandidates(String authorUsername) async {
    final username = _normalizeUsername(authorUsername);
    if (username.isEmpty || username == 'unknown_user') {
      return const <String>[];
    }

    final candidates = <String>{};

    try {
      final uri = Uri.https(
        'duckduckgo.com',
        '/html/',
        {'q': 'site:x.com/$username @$username X'},
      );
      final response = await _dio.get<String>(
        uri.toString(),
        options: Options(
          responseType: ResponseType.plain,
          receiveTimeout: const Duration(seconds: 4),
          sendTimeout: const Duration(seconds: 4),
          headers: const {
            'user-agent': 'XViewer display name lookup',
          },
        ),
      );
      candidates.addAll(
        _extractDisplayNames(
          (response.data ?? '').substring(
            0,
            (response.data ?? '').length.clamp(0, 120000),
          ),
          username,
        ),
      );
    } catch (error) {
      debugPrint(
        '[xviewer][flutter] display name search failed: $error',
      );
    }

    return candidates.take(8).toList(growable: false);
  }

  List<String> _extractDisplayNames(String html, String username) {
    final decoded = _decodeHtml(html);
    final patterns = [
      RegExp(
        r'>([^<>]{1,80})\s*\(@?' + RegExp.escape(username) + r'\)\s*[/|-]\s*X<',
        caseSensitive: false,
      ),
      RegExp(
        RegExp.escape('@$username') + r'\s*[\)-]\s*([^<>]{1,80})\s*[/|-]\s*X',
        caseSensitive: false,
      ),
    ];
    final names = <String>{};

    for (final pattern in patterns) {
      for (final match in pattern.allMatches(decoded)) {
        for (var i = 1; i <= match.groupCount; i += 1) {
          final name = _cleanCandidate(match.group(i) ?? '');
          if (_isUsefulCandidate(name, username)) {
            names.add(name);
          }
        }
      }
    }

    return names.toList(growable: false);
  }

  String _cleanCandidate(String value) {
    return value
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  bool _isUsefulCandidate(String value, String username) {
    if (value.length < 2 || value.length > 50) {
      return false;
    }
    final lower = value.toLowerCase();
    return lower != username &&
        lower != '@$username' &&
        !lower.contains('search') &&
        !lower.contains('twitter') &&
        !lower.contains('login') &&
        !lower.contains('profile');
  }

  String _decodeHtml(String value) {
    return value
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');
  }

  String _normalizeUsername(String value) {
    return value.trim().replaceFirst(RegExp(r'^@+'), '').toLowerCase();
  }
}
