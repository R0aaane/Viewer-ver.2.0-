import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/folder.dart';
import '../models/mediaItem.dart';
import '../models/metadata_settings.dart';
import '../models/tag.dart';
import '../models/tag_with_id.dart';
import '../repository/mediaRepository.dart';
import '../services/app_settings_service.dart';
import '../services/media_id_resolver.dart';
import '../services/remote_tag_api_client.dart';
import 'app_db.dart';
import 'local_tag_store.dart';

export '../models/tag_with_id.dart';

class TagService {
  final LocalTagStore _localStore;
  final AppSettingsService _settingsService;
  final MediaIdResolver _idResolver;

  MetadataSettings _settings = const MetadataSettings();
  RemoteTagApiClient? _remoteClient;
  Future<void>? _initializeFuture;

  final Map<String, MediaItem> _knownItems = <String, MediaItem>{};
  final Map<int, String> _remoteTagIdLookup = <int, String>{};
  final Map<String, Future<List<RemoteTagRecord>>> _remoteTagCache =
      <String, Future<List<RemoteTagRecord>>>{};

  TagService(AppDb db)
      : _localStore = LocalTagStore(db),
        _settingsService = AppSettingsService(),
        _idResolver = MediaIdResolver();

  MetadataSettings get settings => _settings;

  bool get isRemoteMode => _settings.storageMode == MetadataStorageMode.remote;

  Future<void> initialize() {
    return _initializeFuture ??= _initializeInternal();
  }

  Future<void> _initializeInternal() async {
    _settings = await _settingsService.loadMetadataSettings();
    _remoteClient = _buildRemoteClient(_settings);
  }

  Future<void> reloadSettings() async {
    _initializeFuture = null;
    await initialize();
  }

  Future<void> updateMetadataSettings(MetadataSettings nextSettings) async {
    await _settingsService.saveMetadataSettings(nextSettings);
    _settings = nextSettings;
    _remoteClient = _buildRemoteClient(_settings);
    _remoteTagCache.clear();
    _remoteTagIdLookup.clear();
  }

  Future<void> updateMetadataMode(MetadataStorageMode mode) async {
    await updateMetadataSettings(_settings.copyWith(storageMode: mode));
  }

  Future<void> updateRemoteApiBaseUrl(String baseUrl) async {
    await updateMetadataSettings(_settings.copyWith(remoteApiBaseUrl: baseUrl.trim()));
  }

  Future<void> updateAuthToken(String? authToken) async {
    await updateMetadataSettings(
      _settings.copyWith(
        authToken: authToken?.trim(),
        clearAuthToken: authToken == null || authToken.trim().isEmpty,
      ),
    );
  }

  Future<MetadataConnectionStatus> checkConnection() async {
    await initialize();

    if (!isRemoteMode) {
      return MetadataConnectionStatus.localMode();
    }

    try {
      final client = _requireRemoteClient();
      return client.checkHealth();
    } on MetadataException catch (error) {
      return MetadataConnectionStatus(
        state: MetadataConnectionState.disconnected,
        message: error.message,
        checkedAt: DateTime.now(),
      );
    }
  }

  Future<MetadataConnectionStatus> checkConnectionForSettings(
    MetadataSettings draftSettings,
  ) async {
    if (draftSettings.storageMode != MetadataStorageMode.remote) {
      return MetadataConnectionStatus.localMode();
    }
    return _buildRemoteClient(draftSettings).checkHealth();
  }

  Future<void> requestRescan() async {
    await initialize();
    if (!isRemoteMode) {
      return;
    }

    final client = _requireRemoteClient();
    await client.requestRescan();
    _remoteTagCache.clear();
  }

  Future<void> requestRescanForSettings(MetadataSettings draftSettings) async {
    if (draftSettings.storageMode != MetadataStorageMode.remote) {
      return;
    }
    await _buildRemoteClient(draftSettings).requestRescan();
  }

  void rememberItem(MediaItem item) {
    for (final key in _itemLookupKeys(item.id)) {
      _knownItems[key] = item;
    }
  }

  void rememberItems(Iterable<MediaItem> items) {
    for (final item in items) {
      rememberItem(item);
    }
  }

  Future<void> addTagToItem(MediaItem item, Tag tag) async {
    await initialize();
    rememberItem(item);

    if (!isRemoteMode) {
      await _localStore.addTagToItem(item, tag);
      return;
    }

    final identity = await _idResolver.resolve(item);
    await _requireRemoteClient().addTagToItem(identity.stableId, tag, identity: identity);
    _remoteTagCache.remove(identity.stableId);
  }

  Future<void> addTagToItems(List<MediaItem> items, Tag tag) async {
    await initialize();
    rememberItems(items);

    if (!isRemoteMode) {
      await _localStore.addTagToItems(items, tag);
      return;
    }

    final targets = items.where((item) => item.kind != MediaKind.folder).toList(growable: false);
    if (targets.isEmpty) {
      return;
    }

    final identities = await _resolveIdentities(targets);
    await _requireRemoteClient().addTagBatch(identities, tag);
    for (final identity in identities) {
      _remoteTagCache.remove(identity.stableId);
    }
  }

  Future<List<TagWithId>> listTagsForItem(
    String itemId, {
    MediaItem? item,
  }) async {
    await initialize();

    if (!isRemoteMode) {
      return _localStore.listTagsForItem(itemId);
    }

    final resolvedItem = item ?? _lookupKnownItem(itemId);
    if (resolvedItem == null) {
      debugPrint('[metadata] listTagsForItem skipped: unknown item $itemId');
      return const <TagWithId>[];
    }

    rememberItem(resolvedItem);

    try {
      final tags = await _loadRemoteTagsForItem(resolvedItem);
      return tags.map(_toTagWithId).toList(growable: false);
    } on MetadataException catch (error, stackTrace) {
      debugPrint('[metadata] listTagsForItem failed: $error\n$stackTrace');
      return const <TagWithId>[];
    }
  }

  Future<Map<String, List<String>>> getTagNamesByItemIds(
    List<String> itemIds, {
    List<MediaItem>? items,
  }) async {
    await initialize();

    if (!isRemoteMode) {
      return _localStore.getTagNamesByItemIds(itemIds);
    }

    final candidates = <MediaItem>[
      if (items != null) ...items,
      ...itemIds
          .map(_lookupKnownItem)
          .whereType<MediaItem>(),
    ];
    return getTagNamesByItems(candidates);
  }

  Future<Map<String, List<String>>> getTagNamesByItems(List<MediaItem> items) async {
    final detailed = await getDetailedTagsByItems(items);
    return detailed.map(
      (key, value) => MapEntry(
        key,
        value.map((entry) => entry.tag.name).toList(growable: false),
      ),
    );
  }

  Future<Map<String, List<TagWithId>>> getDetailedTagsByItems(List<MediaItem> items) async {
    await initialize();

    final targets = items.where((item) => item.kind != MediaKind.folder).toList(growable: false);
    rememberItems(targets);

    if (!isRemoteMode) {
      final result = <String, List<TagWithId>>{};
      for (final item in targets) {
        result[item.id] = await _localStore.listTagsForItem(item.id);
      }
      return result;
    }

    final result = <String, List<TagWithId>>{};
    final chunks = _chunkItems(targets, 8);

    try {
      for (final chunk in chunks) {
        final loaded = await Future.wait(
          chunk.map((item) async {
            final tags = await _loadRemoteTagsForItem(item);
            return MapEntry(
              item.id,
              tags.map(_toTagWithId).toList(growable: false),
            );
          }),
        );

        for (final entry in loaded) {
          result[entry.key] = entry.value;
        }
      }
    } on MetadataException catch (error, stackTrace) {
      debugPrint('[metadata] getDetailedTagsByItems failed: $error\n$stackTrace');
    }

    return result;
  }

  Future<List<String>> findItemIdsByTag({
    required String folderRaw,
    required TagCategory category,
    required String name,
    bool partial = false,
    List<MediaItem>? candidates,
  }) async {
    await initialize();

    if (!isRemoteMode) {
      if (candidates != null && candidates.isNotEmpty) {
        final items = candidates.where((item) => item.kind != MediaKind.folder).toList(growable: false);
        final details = await getDetailedTagsByItems(items);
        return items
            .where(
              (item) => (details[item.id] ?? const <TagWithId>[]).any(
                (tag) =>
                    tag.tag.category == category &&
                    (partial
                        ? tag.tag.name.toLowerCase().contains(name.toLowerCase())
                        : tag.tag.name == name),
              ),
            )
            .map((item) => item.id)
            .toList(growable: false);
      }

      return _localStore.findItemIdsByTag(
        folderRaw: folderRaw,
        category: category,
        name: name,
        partial: partial,
      );
    }

    final items = (candidates ?? const <MediaItem>[])
        .where(
          (item) =>
              item.kind != MediaKind.folder &&
              (folderRaw.isEmpty || item.folderRaw == folderRaw),
        )
        .toList(growable: false);
    if (items.isEmpty) {
      return const <String>[];
    }

    if (!partial && (category == TagCategory.artist || category == TagCategory.series)) {
      final matchedIds = await findItemIdsByArtistSeriesInCandidates(
        candidates: items,
        artist: category == TagCategory.artist ? name : null,
        series: category == TagCategory.series ? name : null,
      );
      if (matchedIds.isNotEmpty) {
        return matchedIds;
      }
    }

    final details = await getDetailedTagsByItems(items);
    return items
        .where(
          (item) => (details[item.id] ?? const <TagWithId>[]).any(
            (tag) =>
                tag.tag.category == category &&
                (partial
                    ? tag.tag.name.toLowerCase().contains(name.toLowerCase())
                    : tag.tag.name == name),
          ),
        )
        .map((item) => item.id)
        .toList(growable: false);
  }

  Future<List<String>> findItemIdsByArtistSeriesInCandidates({
    required List<MediaItem> candidates,
    String? artist,
    String? series,
  }) async {
    await initialize();

    final items = candidates.where((item) => item.kind != MediaKind.folder).toList(growable: false);
    if (items.isEmpty) {
      return const <String>[];
    }

    if (!isRemoteMode) {
      final details = await getDetailedTagsByItems(items);
      return items
          .where(
            (item) => _matchesArtistSeries(
              details[item.id] ?? const <TagWithId>[],
              artist: artist,
              series: series,
            ),
          )
          .map((item) => item.id)
          .toList(growable: false);
    }

    try {
      final remoteIds = await _requireRemoteClient().searchItemIds(
        artist: artist,
        series: series,
      );
      return await _mapStableIdsToItemIds(items, remoteIds);
    } on MetadataException catch (error, stackTrace) {
      debugPrint('[metadata] remote artist/series search failed: $error\n$stackTrace');
      final details = await getDetailedTagsByItems(items);
      return items
          .where(
            (item) => _matchesArtistSeries(
              details[item.id] ?? const <TagWithId>[],
              artist: artist,
              series: series,
            ),
          )
          .map((item) => item.id)
          .toList(growable: false);
    }
  }

  Future<List<String>> findUntaggedItemIdsInCandidates(List<MediaItem> candidates) async {
    await initialize();

    final items = candidates.where((item) => item.kind != MediaKind.folder).toList(growable: false);
    if (items.isEmpty) {
      return const <String>[];
    }

    if (!isRemoteMode) {
      final details = await getDetailedTagsByItems(items);
      return items
          .where((item) => (details[item.id] ?? const <TagWithId>[]).isEmpty)
          .map((item) => item.id)
          .toList(growable: false);
    }

    try {
      final remoteIds = await _requireRemoteClient().fetchUntaggedIds();
      return await _mapStableIdsToItemIds(items, remoteIds);
    } on MetadataException catch (error, stackTrace) {
      debugPrint('[metadata] remote untagged search failed: $error\n$stackTrace');
      final details = await getDetailedTagsByItems(items);
      return items
          .where((item) => (details[item.id] ?? const <TagWithId>[]).isEmpty)
          .map((item) => item.id)
          .toList(growable: false);
    }
  }

  Future<void> removeTagFromItem(
    String itemId,
    int tagId, {
    MediaItem? item,
  }) async {
    await initialize();

    if (!isRemoteMode) {
      await _localStore.removeTagFromItem(itemId, tagId);
      return;
    }

    final resolvedItem = item ?? _lookupKnownItem(itemId);
    if (resolvedItem == null) {
      throw const MetadataException('対象アイテムの情報が不足しているため、タグを削除できません');
    }

    final identity = await _idResolver.resolve(resolvedItem);
    final remoteTagId = _remoteTagIdLookup[tagId];
    if (remoteTagId == null) {
      throw const MetadataException('タグ識別子を解決できなかったため、削除できません');
    }

    await _requireRemoteClient().deleteItemTag(identity.stableId, remoteTagId);
    _remoteTagCache.remove(identity.stableId);
  }

  Future<List<TagWithId>> listTagMasterByCategory(
    TagCategory category, {
    String? contains,
    int limit = 200,
  }) async {
    await initialize();

    if (!isRemoteMode) {
      return _localStore.listTagMasterByCategory(
        category,
        contains: contains,
        limit: limit,
      );
    }

    try {
      final tags = await _requireRemoteClient().fetchMasterTags(
        category,
        contains: contains,
        limit: limit,
      );
      return tags.map(_toTagWithId).toList(growable: false);
    } on MetadataException catch (error, stackTrace) {
      debugPrint('[metadata] listTagMasterByCategory failed: $error\n$stackTrace');
      return const <TagWithId>[];
    }
  }

  Future<List<Tag>> listTagsByCategory(TagCategory category) async {
    await initialize();

    if (!isRemoteMode) {
      return _localStore.listTagsByCategory(category);
    }

    final masters = await listTagMasterByCategory(category, limit: 500);
    return masters.map((entry) => entry.tag).toList(growable: false);
  }

  Future<List<MediaItem>> findMediaItemsByTagGlobal({
    required TagCategory category,
    required String name,
    bool partial = false,
  }) async {
    await initialize();
    if (!isRemoteMode) {
      return _localStore.findMediaItemsByTagGlobal(
        category: category,
        name: name,
        partial: partial,
      );
    }

    return const <MediaItem>[];
  }

  Future<List<MediaItem>> findMediaItemsByTagAcrossFolders({
    required TagCategory category,
    required String name,
    required MediaRepository repo,
    required List<String> folderRaws,
    bool partial = false,
  }) async {
    await initialize();

    if (!isRemoteMode) {
      return _localStore.findMediaItemsByTagGlobal(
        category: category,
        name: name,
        partial: partial,
      );
    }

    final allItems = await _loadAllMediaAcrossFolders(repo, folderRaws);
    final ids = await findItemIdsByTag(
      folderRaw: '',
      category: category,
      name: name,
      partial: partial,
      candidates: allItems,
    );
    final matched = ids.toSet();
    return allItems.where((item) => matched.contains(item.id)).toList(growable: false);
  }

  Future<Map<String, String>> organizeAppLibrary({
    required String libraryRoot,
  }) async {
    await initialize();

    if (isRemoteMode) {
      throw const MetadataException('リモートメタデータモードでは、ライブラリ整理はまだ未対応です');
    }

    return _localStore.organizeAppLibrary(libraryRoot: libraryRoot);
  }

  Future<void> handleItemRenamed(MediaItem before, MediaItem after) async {
    await initialize();
    rememberItem(after);

    if (!isRemoteMode) {
      await _localStore.renameItem(before, after);
      return;
    }

    final beforeIdentity = await _idResolver.resolve(before);
    final afterIdentity = await _idResolver.resolve(after);

    await _requireRemoteClient().notifyRename(
      beforeItem: before,
      afterItem: after,
      before: beforeIdentity,
      after: afterIdentity,
    );

    _remoteTagCache.remove(beforeIdentity.stableId);
    _remoteTagCache.remove(afterIdentity.stableId);
  }

  Future<void> handleDeletedItems(List<MediaItem> items) async {
    await initialize();
    final targets = items.where((item) => item.kind != MediaKind.folder).toList(growable: false);
    if (targets.isEmpty) {
      return;
    }

    if (!isRemoteMode) {
      await _localStore.deleteItemsByIds(targets.map((item) => item.id).toList(growable: false));
      return;
    }

    final payload = <(MediaItem, ResolvedMediaIdentity)>[];
    for (final item in targets) {
      payload.add((item, await _idResolver.resolve(item)));
    }

    await _requireRemoteClient().notifyDelete(payload);
    for (final entry in payload) {
      _remoteTagCache.remove(entry.$2.stableId);
    }
  }

  RemoteTagApiClient _buildRemoteClient(MetadataSettings settings) {
    return RemoteTagApiClient(
      baseUrl: settings.remoteApiBaseUrl,
      defaultHeadersProvider: () {
        final headers = <String, String>{};
        final token = settings.authToken?.trim();
        if (token != null && token.isNotEmpty) {
          headers['Authorization'] = 'Bearer $token';
        }
        return headers;
      },
    );
  }

  RemoteTagApiClient _requireRemoteClient() {
    final client = _remoteClient;
    if (client == null || !client.isConfigured) {
      throw const MetadataException('リモート API の URL が未設定です');
    }
    return client;
  }

  MediaItem? _lookupKnownItem(String itemId) {
    for (final key in _itemLookupKeys(itemId)) {
      final item = _knownItems[key];
      if (item != null) {
        return item;
      }
    }
    return null;
  }

  List<String> _itemLookupKeys(String raw) {
    return <String>[
      raw,
      raw.replaceAll('\\', '/'),
      raw.replaceAll('/', '\\'),
      raw.toLowerCase(),
      raw.replaceAll('\\', '/').toLowerCase(),
      raw.replaceAll('/', '\\').toLowerCase(),
    ];
  }

  Future<List<RemoteTagRecord>> _loadRemoteTagsForItem(MediaItem item) async {
    final identity = await _idResolver.resolve(item);
    final cached = _remoteTagCache[identity.stableId];
    if (cached != null) {
      return cached;
    }

    final future = _requireRemoteClient().fetchItemTags(identity.stableId);
    _remoteTagCache[identity.stableId] = future;
    return future;
  }

  TagWithId _toTagWithId(RemoteTagRecord record) {
    final hashedId = _fnv1a32(record.rawId);
    _remoteTagIdLookup[hashedId] = record.rawId;
    return TagWithId(tagId: hashedId, tag: record.tag);
  }

  int _fnv1a32(String input) {
    const int offset = 0x811C9DC5;
    const int prime = 0x01000193;

    var hash = offset;
    for (final unit in input.codeUnits) {
      hash ^= unit;
      hash = (hash * prime) & 0xFFFFFFFF;
    }
    return hash & 0x7FFFFFFF;
  }

  Future<List<ResolvedMediaIdentity>> _resolveIdentities(List<MediaItem> items) async {
    final result = <ResolvedMediaIdentity>[];
    final chunks = _chunkItems(items, 8);
    for (final chunk in chunks) {
      final resolved = await Future.wait(chunk.map(_idResolver.resolve));
      result.addAll(resolved);
    }
    return result;
  }

  Future<List<String>> _mapStableIdsToItemIds(
    List<MediaItem> items,
    Set<String> stableIds,
  ) {
    if (stableIds.isEmpty) {
      return Future.value(const <String>[]);
    }

    final matched = <String>[];
    return () async {
      final chunks = _chunkItems(items, 8);
      for (final chunk in chunks) {
        final resolved = await Future.wait(
          chunk.map((item) async => MapEntry(item.id, await _idResolver.resolve(item))),
        );
        for (final entry in resolved) {
          if (stableIds.contains(entry.value.stableId)) {
            matched.add(entry.key);
          }
        }
      }
      return matched;
    }();
  }

  bool _matchesArtistSeries(
    List<TagWithId> tags, {
    String? artist,
    String? series,
  }) {
    final lowerArtist = artist?.toLowerCase();
    final lowerSeries = series?.toLowerCase();

    final hasArtist = lowerArtist == null ||
        tags.any(
          (tag) =>
              tag.tag.category == TagCategory.artist &&
              tag.tag.name.toLowerCase() == lowerArtist,
        );
    final hasSeries = lowerSeries == null ||
        tags.any(
          (tag) =>
              tag.tag.category == TagCategory.series &&
              tag.tag.name.toLowerCase() == lowerSeries,
        );

    return hasArtist && hasSeries;
  }

  Future<List<MediaItem>> _loadAllMediaAcrossFolders(
    MediaRepository repo,
    List<String> folderRaws,
  ) async {
    final all = <MediaItem>[];
    final seen = <String>{};

    for (final folderRaw in folderRaws) {
      final loaded = await repo.listMediaRecursiveFiles(FolderHandle(folderRaw));
      for (final item in loaded) {
        if (item.kind == MediaKind.folder) {
          continue;
        }
        if (seen.add(item.id)) {
          all.add(item);
        }
      }
    }

    rememberItems(all);
    return all;
  }

  List<List<MediaItem>> _chunkItems(List<MediaItem> items, int size) {
    final chunks = <List<MediaItem>>[];
    for (var index = 0; index < items.length; index += size) {
      chunks.add(
        items.sublist(
          index,
          (index + size) > items.length ? items.length : (index + size),
        ),
      );
    }
    return chunks;
  }
}
