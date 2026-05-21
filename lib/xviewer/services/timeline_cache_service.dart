import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/storage_keys.dart';
import '../features/timeline/presentation/models/timeline_state.dart';

class TimelineCacheService {
  const TimelineCacheService();

  Future<TimelineState?> read(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(userId));
    if (raw == null || raw.isEmpty) {
      return null;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        if (decoded is! Map) {
          await clear(userId);
          return null;
        }
      }
      if (decoded is! Map<String, dynamic>) {
        final normalized = Map<String, dynamic>.from(decoded as Map);
        return TimelineState.fromJson(normalized);
      }
      return TimelineState.fromJson(decoded);
    } on FormatException {
      await clear(userId);
      return null;
    }
  }

  Future<void> write({
    required String userId,
    required TimelineState state,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(userId), jsonEncode(state.toJson()));
  }

  Future<void> clear(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(userId));
  }

  String _key(String userId) => '${StorageKeys.timelineCachePrefix}$userId';
}
