import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/folder.dart';
import '../models/mediaItem.dart';
import '../models/metadata_settings.dart';
import '../models/tag.dart';
import '../models/tag_with_id.dart';
import '../repository/mediaRepository.dart';
import '../services/app_settings_service.dart';
import '../services/import_source_normalizer.dart';
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

  bool get isRemoteMode => _settings.isClientMode;
  bool get isHostMode => _settings.isHostMode;

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

  Future<MetadataConnectionStatus> checkConnection() async {
    await initialize();

    if (_settings.isStandaloneMode) {
      return MetadataConnectionStatus.localMode();
    }

    try {
      final client = _requireApiClient();
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
    if (draftSettings.isStandaloneMode) {
      return MetadataConnectionStatus.localMode();
    }
    return _buildRemoteClient(draftSettings).checkHealth();
  }

  Future<void> requestRescan() async {
    await initialize();
    if (_settings.isStandaloneMode) {
      return;
    }

    final client = _requireApiClient();
    await client.requestRescan();
    _remoteTagCache.clear();
  }

  Future<void> requestRescanForSettings(MetadataSettings draftSettings) async {
    if (draftSettings.isStandaloneMode) {
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

    if (isRemoteMode) {
      final identity = await _idResolver.resolve(item);
      await _requireApiClient().addTagToItem(
        identity.stableId,
        tag,
        identity: identity,
      );
      _remoteTagCache.remove(identity.stableId);
      return;
    }

    await _localStore.addTagToItem(item, tag);
    await _replaceHostMirrorTagsForItem(item);
  }

  Future<void> addTagsToItem(MediaItem item, Iterable<Tag> tags) async {
    await initialize();
    rememberItem(item);

    final uniqueTags = _dedupeTags(tags);
    if (uniqueTags.isEmpty) {
      return;
    }

    if (isRemoteMode) {
      final identity = await _idResolver.resolve(item);
      for (final tag in uniqueTags) {
        await _requireApiClient().addTagToItem(
          identity.stableId,
          tag,
          identity: identity,
        );
      }
      _remoteTagCache.remove(identity.stableId);
      return;
    }

    for (final tag in uniqueTags) {
      await _localStore.addTagToItem(item, tag);
    }
    await _replaceHostMirrorTagsForItem(item);
  }

  Future<void> addTagToItems(List<MediaItem> items, Tag tag) async {
    await initialize();
    rememberItems(items);

    if (isRemoteMode) {
      final targets = items
          .where((item) => item.kind != MediaKind.folder)
          .toList(growable: false);
      if (targets.isEmpty) {
        return;
      }

      for (final item in targets) {
        final identity = await _idResolver.resolve(item);
        await _requireApiClient().addTagToItem(
          identity.stableId,
          tag,
          identity: identity,
        );
        _remoteTagCache.remove(identity.stableId);
      }
      return;
    }

    await _localStore.addTagToItems(items, tag);
    for (final item in items.where((entry) => entry.kind != MediaKind.folder)) {
      await _replaceHostMirrorTagsForItem(item);
    }
  }

  List<Tag> _dedupeTags(Iterable<Tag> tags) {
    final out = <Tag>[];
    final seen = <String>{};
    for (final tag in tags) {
      final name = tag.name.trim();
      if (name.isEmpty) {
        continue;
      }
      final key = '${tag.category.name}\u0000${name.toLowerCase()}';
      if (!seen.add(key)) {
        continue;
      }
      out.add(Tag(name: name, category: tag.category));
    }
    return out;
  }

  Future<List<TagWithId>> listTagsForItem(
    String itemId, {
    MediaItem? item,
  }) async {
    await initialize();

    if (!isRemoteMode) {
      final resolvedItem = item ?? _lookupKnownItem(itemId);
      if (isHostMode && resolvedItem != null) {
        await _mergeHostMirrorTagsIntoLocalStore(resolvedItem);
      }
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
      ...itemIds.map(_lookupKnownItem).whereType<MediaItem>(),
    ];
    return getTagNamesByItems(candidates);
  }

  Future<Map<String, List<String>>> getTagNamesByItems(
    List<MediaItem> items,
  ) async {
    final detailed = await getDetailedTagsByItems(items);
    return detailed.map(
      (key, value) => MapEntry(
        key,
        value.map((entry) => entry.tag.name).toList(growable: false),
      ),
    );
  }

  Future<Map<String, List<TagWithId>>> getDetailedTagsByItems(
    List<MediaItem> items,
  ) async {
    await initialize();

    final targets = items
        .where((item) => item.kind != MediaKind.folder)
        .toList(growable: false);
    rememberItems(targets);

    if (!isRemoteMode) {
      if (isHostMode && targets.isNotEmpty && targets.length <= 20) {
        for (final item in targets) {
          await _mergeHostMirrorTagsIntoLocalStore(item);
        }
      }
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
        final items = candidates
            .where((item) => item.kind != MediaKind.folder)
            .toList(growable: false);
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

    if (!partial &&
        (category == TagCategory.artist || category == TagCategory.series)) {
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

    final items = candidates
        .where((item) => item.kind != MediaKind.folder)
        .toList(growable: false);
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
      final remoteIds = await _requireApiClient().searchItemIds(
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

  Future<List<String>> findUntaggedItemIdsInCandidates(
    List<MediaItem> candidates,
  ) async {
    await initialize();

    final items = candidates
        .where((item) => item.kind != MediaKind.folder)
        .toList(growable: false);
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
      final remoteIds = await _requireApiClient().fetchUntaggedIds();
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
      final resolvedItem = item ?? _lookupKnownItem(itemId);
      Tag? removedTag;
      if (resolvedItem != null) {
        final currentTags = await _localStore.listTagsForItem(itemId);
        for (final entry in currentTags) {
          if (entry.tagId == tagId) {
            removedTag = entry.tag;
            break;
          }
        }
      }
      await _localStore.removeTagFromItem(itemId, tagId);
      if (resolvedItem != null) {
        await _replaceHostMirrorTagsForItem(
          resolvedItem,
          excludedTags: removedTag == null
              ? const <Tag>[]
              : <Tag>[removedTag],
        );
      }
      return;
    }

    final resolvedItem = item ?? _lookupKnownItem(itemId);
    if (resolvedItem == null) {
      throw const MetadataException(
        '対象アイテムの情報が見つからないため、タグを削除できません',
      );
    }

    final identity = await _idResolver.resolve(resolvedItem);
    final remoteTagId = _remoteTagIdLookup[tagId];
    if (remoteTagId == null) {
      throw const MetadataException('タグ ID を解決できないため、削除できません');
    }

    await _requireApiClient().deleteItemTag(
      identity.stableId,
      remoteTagId,
      identity: identity,
    );
    _remoteTagCache.remove(identity.stableId);
  }

  Future<void> deleteTagMaster(TagWithId tag) async {
    await initialize();

    if (!isRemoteMode) {
      String? remoteTagId = _remoteTagIdLookup[tag.tagId];
      final client = _hostMirrorClient;
      if (client != null && remoteTagId == null) {
        remoteTagId = await _findRemoteMasterTagId(tag.tag);
      }
      if (client != null && remoteTagId != null) {
        await client.deleteMasterTag(remoteTagId);
      }
      await _localStore.deleteTagMaster(tag.tagId);
      _remoteTagIdLookup.remove(tag.tagId);
      _remoteTagCache.clear();
      return;
    }

    var remoteTagId = _remoteTagIdLookup[tag.tagId];
    if (remoteTagId == null) {
      remoteTagId = await _findRemoteMasterTagId(tag.tag);
    }
    if (remoteTagId == null) {
      throw const MetadataException('タグ ID を解決できないため、削除できません');
    }

    final client = _requireApiClient();
    try {
      await client.deleteMasterTag(remoteTagId);
    } on MetadataException catch (error, stackTrace) {
      final refreshedRemoteTagId = await _findRemoteMasterTagId(tag.tag);
      if (refreshedRemoteTagId == null || refreshedRemoteTagId == remoteTagId) {
        debugPrint(
          '[metadata] delete master tag failed: '
          'tag=${tag.tag.category.name}:${tag.tag.name} '
          'remoteTagId=$remoteTagId error=$error\n$stackTrace',
        );
        rethrow;
      }
      remoteTagId = refreshedRemoteTagId;
      await client.deleteMasterTag(remoteTagId);
    }
    _remoteTagIdLookup.remove(tag.tagId);
    _remoteTagCache.clear();
  }

  Future<String?> _findRemoteMasterTagId(Tag tag) async {
    try {
      final matches = await _requireApiClient().fetchMasterTags(
        tag.category,
        contains: tag.name,
        limit: 500,
      );
      for (final entry in matches) {
        if (entry.tag.category == tag.category && entry.tag.name == tag.name) {
          return entry.rawId;
        }
      }
    } on MetadataException catch (error, stackTrace) {
      debugPrint('[metadata] resolve remote master tag id failed: $error\n$stackTrace');
    }
    return null;
  }

  Future<List<TagWithId>> listTagMasterByCategory(
    TagCategory category, {
    String? contains,
    int limit = 200,
  }) async {
    await initialize();

    if (!isRemoteMode) {
      if (isHostMode) {
        await _syncHostMirrorMasterTags(
          category,
          contains: contains,
          limit: limit,
        );
      }
      return _localStore.listTagMasterByCategory(
        category,
        contains: contains,
        limit: limit,
      );
    }

    try {
      final tags = await _requireApiClient().fetchMasterTags(
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
      if (!isHostMode) {
        return _localStore.listTagsByCategory(category);
      }
      final masters = await listTagMasterByCategory(category, limit: 500);
      return masters.map((entry) => entry.tag).toList(growable: false);
    }

    final masters = await listTagMasterByCategory(category, limit: 500);
    return masters.map((entry) => entry.tag).toList(growable: false);
  }

  Future<List<Tag>> listLocallyStoredTagsForItem(MediaItem item) async {
    await initialize();
    return _listLocallyStoredTagsForItemInternal(item);
  }

  Future<Map<String, List<Tag>>> listLocallyStoredTagsForItems(
    List<MediaItem> items,
  ) async {
    await initialize();

    final result = <String, List<Tag>>{};
    for (final item in items.where((entry) => entry.kind != MediaKind.folder)) {
      final tags = await _listLocallyStoredTagsForItemInternal(item);
      for (final key in _localItemLookupKeys(item.id)) {
        result[key] = tags;
      }
    }
    return result;
  }

  Future<List<MediaItem>> findMediaItemsByTagGlobal({
    required TagCategory category,
    required String name,
    bool partial = false,
  }) async {
    await initialize();
    if (!isRemoteMode) {
      final items = await _localStore.findMediaItemsByTagGlobal(
        category: category,
        name: name,
        partial: partial,
      );
      return items.where(_itemStillExists).toList(growable: false);
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
      final items = await _localStore.findMediaItemsByTagGlobal(
        category: category,
        name: name,
        partial: partial,
      );
      return items.where(_itemStillExists).toList(growable: false);
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
    return allItems.where((item) => matched.contains(item.id)).toList(
      growable: false,
    );
  }

  Future<Map<String, String>> organizeAppLibrary({
    required String libraryRoot,
  }) async {
    await initialize();

    if (isRemoteMode) {
      throw const MetadataException(
        'クライアントモードではライブラリ整理は未対応です',
      );
    }

    return _localStore.organizeAppLibrary(libraryRoot: libraryRoot);
  }

  // Repository is responsible for the actual filesystem / remote action.
  // TagService only keeps metadata stores and caches in sync with that result.
  Future<void> handleItemRenamed(MediaItem before, MediaItem after) async {
    await initialize();
    _forgetKnownItem(before);
    rememberItem(after);

    if (!isRemoteMode) {
      await _localStore.renameItem(before, after);
      await _mirrorHostRename(before, after);
      return;
    }

    final beforeIdentity = await _idResolver.resolve(before);
    final afterIdentity = await _idResolver.resolve(after);
    _remoteTagCache.remove(beforeIdentity.stableId);
    _remoteTagCache.remove(afterIdentity.stableId);
  }

  Future<void> handleDeletedItems(List<MediaItem> items) async {
    await initialize();
    final targets = items
        .where((item) => item.kind != MediaKind.folder)
        .toList(growable: false);
    if (targets.isEmpty) {
      return;
    }

    if (!isRemoteMode) {
      await _localStore.deleteItemsByIds(
        targets.map((item) => item.id).toList(growable: false),
      );
      await _mirrorHostDelete(targets);
      for (final item in targets) {
        _forgetKnownItem(item);
      }
      return;
    }

    for (final item in targets) {
      final identity = await _idResolver.resolve(item);
      _remoteTagCache.remove(identity.stableId);
      _forgetKnownItem(item);
    }
  }

  Future<void> syncLocalTagsToHost() async {
    await initialize();
    if (!isHostMode) {
      return;
    }

    final client = _hostMirrorClient;
    if (client == null) {
      return;
    }

    try {
      await client.requestRescan();
      final items = await _localStore.listStoredMediaItems();
      for (final item in items) {
        if (item.kind == MediaKind.folder) {
          continue;
        }
        if (!_itemStillExists(item)) {
          continue;
        }
        await _replaceHostMirrorTagsForItem(item);
      }
    } on MetadataException catch (error, stackTrace) {
      debugPrint('[host-mirror] full sync failed: $error\n$stackTrace');
    }
  }

  bool _itemStillExists(MediaItem item) {
    if (item.id.startsWith('content://')) {
      return true;
    }
    try {
      return File(item.id).existsSync();
    } catch (_) {
      return false;
    }
  }

  Future<void> _replaceHostMirrorTagsForItem(
    MediaItem item, {
    Iterable<Tag> excludedTags = const <Tag>[],
  }) async {
    final client = _hostMirrorClient;
    if (client == null || item.kind == MediaKind.folder) {
      return;
    }

    final excludedKeys = excludedTags
        .map(_tagLookupKey)
        .whereType<String>()
        .toSet();
    await _mergeHostMirrorTagsIntoLocalStore(
      item,
      excludedTagKeys: excludedKeys,
    );
    final currentTags = await _listLocallyStoredTagsForItemInternal(item);
    final tags = currentTags.where((tag) {
      final key = _tagLookupKey(tag);
      return key == null || !excludedKeys.contains(key);
    }).toList(growable: false);
    final identity = await _idResolver.resolve(item);

    await _runHostMirror(
      () => client.replaceTagsForItem(
        identity.stableId,
        tags,
        identity: identity,
      ),
      retryAfterRescan: true,
    );
  }

  Future<void> _mergeHostMirrorTagsIntoLocalStore(
    MediaItem item, {
    Set<String> excludedTagKeys = const <String>{},
  }) async {
    final client = _hostMirrorClient;
    if (client == null || item.kind == MediaKind.folder) {
      return;
    }

    final localTags = await _listLocallyStoredTagsForItemInternal(item);
    final knownKeys = localTags
        .map(_tagLookupKey)
        .whereType<String>()
        .toSet();
    final identity = await _idResolver.resolve(item);

    try {
      final remoteTags = await client.fetchItemTags(
        identity.stableId,
        identity: identity,
      );
      final missing = <Tag>[];
      for (final entry in remoteTags) {
        final normalizedName = entry.tag.name.trim();
        if (normalizedName.isEmpty) {
          continue;
        }
        final tag = Tag(name: normalizedName, category: entry.tag.category);
        final key = _tagLookupKey(tag);
        if (key == null ||
            excludedTagKeys.contains(key) ||
            knownKeys.contains(key)) {
          continue;
        }
        knownKeys.add(key);
        missing.add(tag);
      }

      for (final tag in missing) {
        await _localStore.addTagToItem(item, tag);
      }

      if (missing.isNotEmpty) {
        debugPrint(
          '[host-mirror] hydrated local tags item=${item.id} '
          'added=${missing.map((tag) => '${tag.category.name}:${tag.name}').join(', ')}',
        );
      }
    } on MetadataException catch (error, stackTrace) {
      debugPrint('[host-mirror] hydrate failed: $error');
      debugPrintStack(
        label: '[host-mirror] hydrate stack',
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _syncHostMirrorMasterTags(
    TagCategory category, {
    String? contains,
    int limit = 200,
  }) async {
    final client = _hostMirrorClient;
    if (client == null) {
      return;
    }

    final trimmedContains = contains?.trim();
    final shouldPrune = trimmedContains == null || trimmedContains.isEmpty;
    final fetchLimit = shouldPrune ? 1000 : limit.clamp(1, 1000);

    try {
      final remoteTags = await client.fetchMasterTags(
        category,
        contains: trimmedContains,
        limit: fetchLimit,
      );
      final remoteKeys = <String>{};

      for (final entry in remoteTags) {
        final key = _tagLookupKey(entry.tag);
        if (key == null) {
          continue;
        }
        remoteKeys.add(key);
        final localId = await _localStore.ensureTagId(entry.tag);
        _remoteTagIdLookup[localId] = entry.rawId;
      }

      if (!shouldPrune) {
        return;
      }

      final localTags = await _localStore.listTagMasterByCategory(
        category,
        limit: fetchLimit,
      );
      for (final localTag in localTags) {
        final key = _tagLookupKey(localTag.tag);
        if (key == null || remoteKeys.contains(key)) {
          continue;
        }
        await _localStore.deleteTagMaster(localTag.tagId);
        _remoteTagIdLookup.remove(localTag.tagId);
      }
    } on MetadataException catch (error, stackTrace) {
      debugPrint('[host-mirror] master tag sync failed: $error\n$stackTrace');
    }
  }

  Future<void> _mirrorHostRename(MediaItem before, MediaItem after) async {
    final client = _hostMirrorClient;
    if (client == null) {
      return;
    }

    final beforeIdentity = await _idResolver.resolve(before);
    final afterIdentity = await _idResolver.resolve(after);
    await _runHostMirror(
      () => client.notifyRename(
        beforeItem: before,
        afterItem: after,
        before: beforeIdentity,
        after: afterIdentity,
      ),
    );
  }

  Future<void> _mirrorHostDelete(List<MediaItem> items) async {
    final client = _hostMirrorClient;
    if (client == null) {
      return;
    }

    final payload = <(MediaItem, ResolvedMediaIdentity)>[];
    for (final item in items) {
      payload.add((item, await _idResolver.resolve(item)));
    }

    await _runHostMirror(() => client.notifyDelete(payload, hardDelete: false));
  }

  Future<void> _runHostMirror(
    Future<void> Function() action, {
    bool retryAfterRescan = false,
  }) async {
    final client = _hostMirrorClient;
    if (client == null) {
      return;
    }

    try {
      await action();
    } on MetadataException catch (error, stackTrace) {
      debugPrint('[host-mirror] sync failed: $error\n$stackTrace');
      if (!retryAfterRescan) {
        return;
      }
      try {
        await client.requestRescan();
        await action();
      } on MetadataException catch (retryError, retryStackTrace) {
        debugPrint(
          '[host-mirror] retry failed: $retryError\n$retryStackTrace',
        );
      }
    }
  }

  RemoteTagApiClient _buildRemoteClient(MetadataSettings settings) {
    final baseUrl = switch (settings.appMode) {
      AppMode.standalone => '',
      AppMode.host => settings.hostLoopbackApiBaseUrl,
      AppMode.client => settings.remoteApiBaseUrl,
    };

    return RemoteTagApiClient(
      baseUrl: baseUrl,
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

  RemoteTagApiClient? get _hostMirrorClient {
    final client = _remoteClient;
    if (!isHostMode || client == null || !client.isConfigured) {
      return null;
    }
    return client;
  }

  RemoteTagApiClient _requireApiClient() {
    final client = _remoteClient;
    if (client == null || !client.isConfigured) {
      throw const MetadataException('API URL が未設定です');
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

  void _forgetKnownItem(MediaItem item) {
    for (final key in _itemLookupKeys(item.id)) {
      _knownItems.remove(key);
    }
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
    late final ResolvedMediaIdentity identity;
    try {
      identity = await _idResolver.resolve(item);
    } catch (error, stackTrace) {
      debugPrint(
        '[metadata] resolve item identity failed: ${item.id}\n$error\n$stackTrace',
      );
      throw MetadataException(
        'メディア識別情報の解決に失敗しました: ${item.displayName}',
      );
    }
    final cached = _remoteTagCache[identity.stableId];
    if (cached != null) {
      return cached;
    }

    final future = _requireApiClient().fetchItemTags(
      identity.stableId,
      identity: identity,
    );
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

  Future<List<ResolvedMediaIdentity>> _resolveIdentities(
    List<MediaItem> items,
  ) async {
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

    final hasArtist =
        lowerArtist == null ||
        tags.any(
          (tag) =>
              tag.tag.category == TagCategory.artist &&
              tag.tag.name.toLowerCase() == lowerArtist,
        );
    final hasSeries =
        lowerSeries == null ||
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

  Future<List<Tag>> _listLocallyStoredTagsForItemInternal(MediaItem item) async {
    final merged = <String, Tag>{};
    for (final itemId in _localItemLookupKeys(item.id)) {
      final current = await _localStore.listTagsForItem(itemId);
      for (final entry in current) {
        final normalizedName = entry.tag.name.trim();
        if (normalizedName.isEmpty) {
          continue;
        }
        final key =
            '${entry.tag.category.name}\u0000${normalizedName.toLowerCase()}';
        merged.putIfAbsent(
          key,
          () => Tag(
            name: normalizedName,
            category: entry.tag.category,
          ),
        );
      }
    }
    return merged.values.toList(growable: false);
  }

  Set<String> _localItemLookupKeys(String raw) {
    final keys = <String>{..._itemLookupKeys(raw)};
    final normalized = ImportSourceNormalizer.normalizeSingleValue(raw)?.trim();
    if (normalized != null && normalized.isNotEmpty) {
      keys.addAll(_itemLookupKeys(normalized));
    }
    return keys;
  }

  String? _tagLookupKey(Tag tag) {
    final normalizedName = tag.name.trim();
    if (normalizedName.isEmpty) {
      return null;
    }
    return '${tag.category.name}\u0000${normalizedName.toLowerCase()}';
  }
}
