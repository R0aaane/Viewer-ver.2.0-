import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/mediaItem.dart';

class HomeActivityEntry {
  final String itemId;
  final String folderRaw;
  final DateTime viewedAt;
  final int? lastPage;

  const HomeActivityEntry({
    required this.itemId,
    required this.folderRaw,
    required this.viewedAt,
    this.lastPage,
  });

  factory HomeActivityEntry.fromJson(Map<String, dynamic> json) {
    final itemId = (json['itemId'] as String?)?.trim() ?? '';
    final folderRaw = (json['folderRaw'] as String?)?.trim() ?? '';
    final viewedAtMs = json['viewedAtMs'];
    final viewedAt = viewedAtMs is int
        ? DateTime.fromMillisecondsSinceEpoch(viewedAtMs)
        : DateTime.fromMillisecondsSinceEpoch(0);
    final pageValue = json['lastPage'];
    final lastPage = pageValue is int && pageValue > 0 ? pageValue : null;

    if (itemId.isEmpty) {
      throw const FormatException('itemId is empty');
    }

    return HomeActivityEntry(
      itemId: itemId,
      folderRaw: folderRaw,
      viewedAt: viewedAt,
      lastPage: lastPage,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'itemId': itemId,
    'folderRaw': folderRaw,
    'viewedAtMs': viewedAt.millisecondsSinceEpoch,
    if (lastPage != null) 'lastPage': lastPage,
  };
}

class HomeActivityStore {
  static const String recentViewsKey = 'prefs.homeRecentViewsJson';
  static const int maxRecentViews = 24;

  static List<HomeActivityEntry> readRecentViews(SharedPreferences prefs) {
    final raw = prefs.getString(recentViewsKey);
    if (raw == null || raw.trim().isEmpty) {
      return const <HomeActivityEntry>[];
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return const <HomeActivityEntry>[];
      }

      final parsed = <HomeActivityEntry>[];
      for (final entry in decoded) {
        if (entry is! Map) {
          continue;
        }
        try {
          parsed.add(
            HomeActivityEntry.fromJson(Map<String, dynamic>.from(entry)),
          );
        } catch (_) {
          continue;
        }
      }

      parsed.sort((a, b) => b.viewedAt.compareTo(a.viewedAt));

      final deduped = <HomeActivityEntry>[];
      final seen = <String>{};
      for (final entry in parsed) {
        if (!seen.add(entry.itemId)) {
          continue;
        }
        deduped.add(entry);
        if (deduped.length >= maxRecentViews) {
          break;
        }
      }
      return deduped.toList(growable: false);
    } catch (_) {
      return const <HomeActivityEntry>[];
    }
  }

  static Future<List<HomeActivityEntry>> recordView(
    SharedPreferences prefs, {
    required MediaItem item,
    int? lastPage,
    int? totalPages,
    DateTime? viewedAt,
  }) async {
    final next = readRecentViews(
      prefs,
    ).where((entry) => entry.itemId != item.id).toList(growable: true);

    final normalizedPage = item.kind == MediaKind.pdf && lastPage != null
        ? (lastPage < 1 ? 1 : lastPage)
        : null;
    final normalizedTotalPages =
        item.kind == MediaKind.pdf && totalPages != null && totalPages > 0
        ? totalPages
        : null;
    final reachedLastPage =
        normalizedPage != null &&
        normalizedTotalPages != null &&
        normalizedPage >= normalizedTotalPages;

    if (!reachedLastPage) {
      next.insert(
        0,
        HomeActivityEntry(
          itemId: item.id,
          folderRaw: item.folderRaw,
          viewedAt: viewedAt ?? DateTime.now(),
          lastPage: normalizedPage,
        ),
      );
    }

    final limited = next.take(maxRecentViews).toList(growable: false);
    final encoded = jsonEncode(
      limited.map((entry) => entry.toJson()).toList(growable: false),
    );
    await prefs.setString(recentViewsKey, encoded);
    return limited;
  }
}
