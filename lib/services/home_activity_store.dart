import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/mediaItem.dart';
import '../models/metadata_settings.dart';
import 'app_settings_service.dart';
import 'media_id_resolver.dart';
import 'remote_media_api_client.dart';

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
  static const int maxRecentViews = 200;
  static final AppSettingsService _settingsService = AppSettingsService();
  static final MediaIdResolver _idResolver = MediaIdResolver();

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

  static Future<List<HomeActivityEntry>> loadRecentViews(
    SharedPreferences prefs,
  ) async {
    final local = readRecentViews(prefs);
    final remote = await _readRemoteRecentViews();
    if (remote == null || remote.isEmpty) {
      return local;
    }

    final merged = _mergeEntries(remote, local);
    await _writeRecentViews(prefs, merged);
    return merged;
  }

  static Future<List<HomeActivityEntry>> recordView(
    SharedPreferences prefs, {
    required MediaItem item,
    int? lastPage,
    int? totalPages,
    DateTime? viewedAt,
  }) async {
    final viewedAtValue = viewedAt ?? DateTime.now();
    ResolvedMediaIdentity? identity;
    try {
      identity = await _idResolver.resolve(item);
    } catch (_) {}

    final entryItemId = identity?.stableId ?? item.id;
    final knownItemIds = <String>{item.id, entryItemId, ...?identity?.aliases};
    final next = readRecentViews(prefs)
        .where((entry) => !knownItemIds.contains(entry.itemId))
        .toList(growable: true);

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
          itemId: entryItemId,
          folderRaw: item.folderRaw,
          viewedAt: viewedAtValue,
          lastPage: normalizedPage,
        ),
      );
    }

    final limited = _mergeEntries(next, const <HomeActivityEntry>[]);
    await _writeRecentViews(prefs, limited);
    await _recordRemoteView(
      item: item,
      identity: identity,
      lastPage: normalizedPage,
      totalPages: normalizedTotalPages,
    );
    return limited;
  }

  static List<HomeActivityEntry> _mergeEntries(
    Iterable<HomeActivityEntry> primary,
    Iterable<HomeActivityEntry> secondary,
  ) {
    final combined = <HomeActivityEntry>[...primary, ...secondary]
      ..sort((a, b) => b.viewedAt.compareTo(a.viewedAt));

    final deduped = <HomeActivityEntry>[];
    final seen = <String>{};
    for (final entry in combined) {
      if (!seen.add(entry.itemId)) {
        continue;
      }
      deduped.add(entry);
      if (deduped.length >= maxRecentViews) {
        break;
      }
    }
    return deduped.toList(growable: false);
  }

  static Future<void> _writeRecentViews(
    SharedPreferences prefs,
    List<HomeActivityEntry> entries,
  ) async {
    final encoded = jsonEncode(
      entries.map((entry) => entry.toJson()).toList(growable: false),
    );
    await prefs.setString(recentViewsKey, encoded);
  }

  static Future<List<HomeActivityEntry>?> _readRemoteRecentViews() async {
    final client = await _buildRemoteClient();
    if (client == null) {
      return null;
    }
    try {
      final entries = await client.fetchRecentMediaActivity(
        limit: maxRecentViews,
      );
      return entries
          .map(
            (entry) => HomeActivityEntry(
              itemId: entry.mediaId,
              folderRaw: entry.folderRaw,
              viewedAt: entry.viewedAt,
              lastPage: entry.lastPage,
            ),
          )
          .toList(growable: false);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _recordRemoteView({
    required MediaItem item,
    required ResolvedMediaIdentity? identity,
    required int? lastPage,
    required int? totalPages,
  }) async {
    final client = await _buildRemoteClient();
    if (client == null) {
      return;
    }

    try {
      await client.recordMediaActivity(
        identity?.stableId ?? item.id,
        identity: identity,
        lastPage: lastPage,
        totalPages: totalPages,
      );
    } catch (_) {}
  }

  static Future<RemoteMediaApiClient?> _buildRemoteClient() async {
    final settings = await _settingsService.loadMetadataSettings();
    final baseUrl = switch (settings.appMode) {
      AppMode.host => settings.hostLoopbackApiBaseUrl,
      AppMode.client => settings.remoteApiBaseUrl,
      AppMode.standalone => '',
    };
    final token = settings.authToken?.trim();
    final client = RemoteMediaApiClient(
      baseUrl: baseUrl,
      authToken: token == null || token.isEmpty ? null : token,
    );
    if (!client.isConfigured) {
      return null;
    }
    return client;
  }
}
