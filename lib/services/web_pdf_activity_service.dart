import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../web/web_remote_api_client.dart';

class WebPdfActivityRecord {
  final String stableId;
  final String? mediaId;
  final String displayName;
  final String folderRaw;
  final DateTime addedAt;
  final DateTime? lastViewedAt;
  final DateTime lastSeenAt;
  final int viewCount;

  const WebPdfActivityRecord({
    required this.stableId,
    required this.mediaId,
    required this.displayName,
    required this.folderRaw,
    required this.addedAt,
    required this.lastViewedAt,
    required this.lastSeenAt,
    required this.viewCount,
  });

  factory WebPdfActivityRecord.fromJson(Map<String, dynamic> json) {
    return WebPdfActivityRecord(
      stableId: (json['stableId'] ?? '').toString(),
      mediaId: json['mediaId']?.toString(),
      displayName: (json['displayName'] ?? '').toString(),
      folderRaw: (json['folderRaw'] ?? '').toString(),
      addedAt: _parseDateTime(json['addedAt']) ?? DateTime.now().toUtc(),
      lastViewedAt: _parseDateTime(json['lastViewedAt']),
      lastSeenAt: _parseDateTime(json['lastSeenAt']) ?? DateTime.now().toUtc(),
      viewCount: _parseInt(json['viewCount']) ?? 0,
    );
  }

  WebPdfActivityRecord copyWith({
    String? mediaId,
    String? displayName,
    String? folderRaw,
    DateTime? addedAt,
    Object? lastViewedAt = _unset,
    DateTime? lastSeenAt,
    int? viewCount,
  }) {
    return WebPdfActivityRecord(
      stableId: stableId,
      mediaId: mediaId ?? this.mediaId,
      displayName: displayName ?? this.displayName,
      folderRaw: folderRaw ?? this.folderRaw,
      addedAt: addedAt ?? this.addedAt,
      lastViewedAt:
          identical(lastViewedAt, _unset)
              ? this.lastViewedAt
              : lastViewedAt as DateTime?,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      viewCount: viewCount ?? this.viewCount,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'stableId': stableId,
      'mediaId': mediaId,
      'displayName': displayName,
      'folderRaw': folderRaw,
      'addedAt': addedAt.toUtc().toIso8601String(),
      'lastViewedAt': lastViewedAt?.toUtc().toIso8601String(),
      'lastSeenAt': lastSeenAt.toUtc().toIso8601String(),
      'viewCount': viewCount,
    };
  }

  static DateTime? _parseDateTime(Object? raw) {
    final text = raw?.toString().trim();
    if (text == null || text.isEmpty) {
      return null;
    }
    return DateTime.tryParse(text)?.toUtc();
  }

  static int? _parseInt(Object? raw) {
    if (raw is int) {
      return raw;
    }
    return int.tryParse(raw?.toString() ?? '');
  }
}

class WebPdfActivityService {
  static const String _storageKey = 'prefs.web.pdfActivity.v1';

  Map<String, WebPdfActivityRecord> _memoryRecords =
      const <String, WebPdfActivityRecord>{};

  Future<Map<String, WebPdfActivityRecord>> loadRecords() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw == null || raw.trim().isEmpty) {
        return _snapshot(_memoryRecords);
      }
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return _snapshot(_memoryRecords);
      }

      final next = <String, WebPdfActivityRecord>{};
      for (final item in decoded) {
        if (item is! Map) {
          continue;
        }
        final record = WebPdfActivityRecord.fromJson(
          item.cast<String, dynamic>(),
        );
        if (record.stableId.trim().isEmpty) {
          continue;
        }
        next[record.stableId] = record;
      }
      _memoryRecords = _snapshot(next);
      return _memoryRecords;
    } catch (error, stackTrace) {
      debugPrint('[WebPdfActivityService] Failed to load records: $error');
      debugPrintStack(
        label: '[WebPdfActivityService] loadRecords',
        stackTrace: stackTrace,
      );
      return _snapshot(_memoryRecords);
    }
  }

  Future<Map<String, WebPdfActivityRecord>> syncEntries(
    Iterable<WebRemoteEntry> entries,
  ) async {
    final now = DateTime.now().toUtc();
    final next = Map<String, WebPdfActivityRecord>.from(await loadRecords());
    var changed = false;

    for (final entry in entries) {
      if (!entry.isPdf) {
        continue;
      }
      final stableId = _stableIdFor(entry);
      if (stableId.isEmpty) {
        continue;
      }
      final current = next[stableId];
      final fallbackAddedAt = (entry.modifiedAt ?? now).toUtc();
      final updated =
          current == null
              ? WebPdfActivityRecord(
                stableId: stableId,
                mediaId: entry.mediaId,
                displayName: entry.displayName,
                folderRaw: entry.folderRaw,
                addedAt: fallbackAddedAt,
                lastViewedAt: null,
                lastSeenAt: now,
                viewCount: 0,
              )
              : current.copyWith(
                mediaId: entry.mediaId,
                displayName: entry.displayName,
                folderRaw: entry.folderRaw,
                lastSeenAt: now,
              );
      if (!_sameRecord(current, updated)) {
        next[stableId] = updated;
        changed = true;
      }
    }

    if (changed) {
      await _saveRecords(next);
      return _snapshot(next);
    }
    _memoryRecords = _snapshot(next);
    return _memoryRecords;
  }

  Future<Map<String, WebPdfActivityRecord>> recordView(
    WebRemoteEntry entry,
  ) async {
    final stableId = _stableIdFor(entry);
    if (stableId.isEmpty) {
      return loadRecords();
    }

    final now = DateTime.now().toUtc();
    final next = Map<String, WebPdfActivityRecord>.from(await loadRecords());
    final current = next[stableId];
    final record =
        (current ??
                WebPdfActivityRecord(
                  stableId: stableId,
                  mediaId: entry.mediaId,
                  displayName: entry.displayName,
                  folderRaw: entry.folderRaw,
                  addedAt: (entry.modifiedAt ?? now).toUtc(),
                  lastViewedAt: null,
                  lastSeenAt: now,
                  viewCount: 0,
                ))
            .copyWith(
              mediaId: entry.mediaId,
              displayName: entry.displayName,
              folderRaw: entry.folderRaw,
              lastViewedAt: now,
              lastSeenAt: now,
              viewCount: (current?.viewCount ?? 0) + 1,
            );
    next[stableId] = record;
    await _saveRecords(next);
    return _snapshot(next);
  }

  String _stableIdFor(WebRemoteEntry entry) {
    final stableId = entry.stableId.trim();
    if (stableId.isNotEmpty) {
      return stableId;
    }
    return (entry.mediaId ?? entry.fullPath ?? entry.entryId).trim();
  }

  Future<void> _saveRecords(Map<String, WebPdfActivityRecord> records) async {
    final snapshot = _snapshot(records);
    _memoryRecords = snapshot;
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload =
          snapshot.values
              .map((record) => record.toJson())
              .toList(growable: false);
      await prefs.setString(_storageKey, jsonEncode(payload));
    } catch (error, stackTrace) {
      debugPrint('[WebPdfActivityService] Failed to save records: $error');
      debugPrintStack(
        label: '[WebPdfActivityService] _saveRecords',
        stackTrace: stackTrace,
      );
    }
  }

  bool _sameRecord(
    WebPdfActivityRecord? left,
    WebPdfActivityRecord right,
  ) {
    if (left == null) {
      return false;
    }
    return left.mediaId == right.mediaId &&
        left.displayName == right.displayName &&
        left.folderRaw == right.folderRaw &&
        left.addedAt == right.addedAt &&
        left.lastViewedAt == right.lastViewedAt &&
        left.lastSeenAt == right.lastSeenAt &&
        left.viewCount == right.viewCount;
  }

  Map<String, WebPdfActivityRecord> _snapshot(
    Map<String, WebPdfActivityRecord> records,
  ) {
    return Map<String, WebPdfActivityRecord>.unmodifiable(
      Map<String, WebPdfActivityRecord>.from(records),
    );
  }
}

const Object _unset = Object();
