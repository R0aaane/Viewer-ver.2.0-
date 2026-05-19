import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/mediaItem.dart' as media;
import '../models/tag.dart' as model;
import '../models/tag_with_id.dart';
import '../services/local_path_operation_service.dart';
import 'app_db.dart' as db;

class LocalTagStore {
  final db.AppDb _db;

  LocalTagStore(this._db);

  int _kindToInt(media.MediaKind kind) => switch (kind) {
    media.MediaKind.image => 0,
    media.MediaKind.pdf => 1,
    media.MediaKind.epub => 2,
    media.MediaKind.folder => 3,
  };

  media.MediaKind _kindFromInt(int kind) => switch (kind) {
    0 => media.MediaKind.image,
    2 => media.MediaKind.epub,
    3 => media.MediaKind.folder,
    _ => media.MediaKind.pdf,
  };

  int _categoryToInt(model.TagCategory category) {
    switch (category) {
      case model.TagCategory.artist:
        return db.TagCategoryDb.artist.index;
      case model.TagCategory.series:
        return db.TagCategoryDb.series.index;
      case model.TagCategory.mediaType:
        return db.TagCategoryDb.mediaType.index;
      case model.TagCategory.character:
        return db.TagCategoryDb.character.index;
      case model.TagCategory.free:
        return db.TagCategoryDb.free.index;
    }
  }

  model.TagCategory _intToCategory(int value) {
    final category = db.TagCategoryDb.values[value];
    switch (category) {
      case db.TagCategoryDb.artist:
        return model.TagCategory.artist;
      case db.TagCategoryDb.series:
        return model.TagCategory.series;
      case db.TagCategoryDb.mediaType:
        return model.TagCategory.mediaType;
      case db.TagCategoryDb.character:
        return model.TagCategory.character;
      case db.TagCategoryDb.free:
        return model.TagCategory.free;
    }
  }

  Future<void> upsertMediaItem(media.MediaItem item) async {
    await _db
        .into(_db.mediaItems)
        .insertOnConflictUpdate(
          db.MediaItemsCompanion.insert(
            id: item.id,
            folderRaw: item.folderRaw,
            displayName: item.displayName,
            kind: _kindToInt(item.kind),
            modifiedEpochMs: Value(item.modified?.millisecondsSinceEpoch),
          ),
        );
  }

  Future<int> ensureTagId(model.Tag tag) async {
    final category = _categoryToInt(tag.category);

    await _db
        .into(_db.tags)
        .insert(
          db.TagsCompanion.insert(name: tag.name, category: category),
          mode: InsertMode.insertOrIgnore,
        );

    final row =
        await (_db.select(_db.tags)..where(
              (table) =>
                  table.name.equals(tag.name) & table.category.equals(category),
            ))
            .getSingleOrNull();
    if (row == null) {
      throw StateError(
        'Failed to create or find tag: ${tag.category.name}:${tag.name}',
      );
    }
    return row.tagId;
  }

  Future<void> addTagToItem(media.MediaItem item, model.Tag tag) async {
    await upsertMediaItem(item);
    final tagId = await ensureTagId(tag);

    await _db
        .into(_db.mediaItemTags)
        .insert(
          db.MediaItemTagsCompanion.insert(itemId: item.id, tagId: tagId),
          mode: InsertMode.insertOrIgnore,
        );
  }

  Future<void> addTagToItems(List<media.MediaItem> items, model.Tag tag) async {
    if (items.isEmpty) {
      return;
    }

    final tagId = await ensureTagId(tag);

    await _db.batch((batch) {
      batch.insertAllOnConflictUpdate(
        _db.mediaItems,
        items
            .map(
              (item) => db.MediaItemsCompanion.insert(
                id: item.id,
                folderRaw: item.folderRaw,
                displayName: item.displayName,
                kind: _kindToInt(item.kind),
                modifiedEpochMs: Value(item.modified?.millisecondsSinceEpoch),
              ),
            )
            .toList(growable: false),
      );

      batch.insertAll(
        _db.mediaItemTags,
        items
            .map(
              (item) => db.MediaItemTagsCompanion.insert(
                itemId: item.id,
                tagId: tagId,
              ),
            )
            .toList(growable: false),
        mode: InsertMode.insertOrIgnore,
      );
    });
  }

  Future<void> removeTagFromItem(String itemId, int tagId) async {
    await (_db.delete(_db.mediaItemTags)..where(
          (table) => table.itemId.equals(itemId) & table.tagId.equals(tagId),
        ))
        .go();
  }

  Future<void> deleteTagMaster(int tagId) async {
    await _db.transaction(() async {
      await (_db.delete(
        _db.mediaItemTags,
      )..where((table) => table.tagId.equals(tagId))).go();
      await (_db.delete(
        _db.tags,
      )..where((table) => table.tagId.equals(tagId))).go();
    });
  }

  Future<void> deleteItemsByIds(List<String> ids) async {
    if (ids.isEmpty) {
      return;
    }

    await _db.transaction(() async {
      await (_db.delete(
        _db.mediaItemTags,
      )..where((table) => table.itemId.isIn(ids))).go();
      await (_db.delete(
        _db.mediaItems,
      )..where((table) => table.id.isIn(ids))).go();
    });
  }

  Future<void> deleteItemsUnderPathPrefix(String prefix) async {
    final like = '${_escapeLike(prefix)}%';
    final rows = await (_db.select(
      _db.mediaItems,
    )..where((table) => table.id.like(like, escapeChar: r'\'))).get();
    if (rows.isEmpty) {
      return;
    }

    final ids = rows.map((row) => row.id).toList(growable: false);
    await deleteItemsByIds(ids);
  }

  Future<void> renameItem(media.MediaItem before, media.MediaItem after) async {
    if (before.id == after.id) {
      await upsertMediaItem(after);
      return;
    }

    await _db.transaction(() async {
      await _moveMediaItemRecord(beforeId: before.id, after: after);
    });
  }

  Future<void> renameItemsUnderPathPrefix({
    required String beforePrefix,
    required String afterPrefix,
  }) async {
    final normalizedBefore = p.normalize(beforePrefix);
    final normalizedAfter = p.normalize(afterPrefix);
    if (normalizedBefore == normalizedAfter) {
      return;
    }

    final rows = await (_db.select(
      _db.mediaItems,
    )..orderBy([(table) => OrderingTerm.asc(table.id)])).get();
    final targets = rows
        .where((row) => _isPathWithinPrefix(row.id, normalizedBefore))
        .toList(growable: false);
    if (targets.isEmpty) {
      return;
    }

    await _db.transaction(() async {
      for (final row in targets) {
        final nextId = _replacePathPrefix(
          row.id,
          normalizedBefore,
          normalizedAfter,
        );
        final nextFolderRaw = _replacePathPrefix(
          row.folderRaw,
          normalizedBefore,
          normalizedAfter,
        );
        await _moveMediaItemRecord(
          beforeId: row.id,
          after: media.MediaItem(
            id: nextId,
            folderRaw: nextFolderRaw,
            displayName: row.displayName,
            kind: _kindFromInt(row.kind),
            modified: row.modifiedEpochMs == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(row.modifiedEpochMs!),
          ),
        );
      }
    });
  }

  Future<List<TagWithId>> listTagsForItem(String itemId) async {
    final rows = await (_db.select(_db.mediaItemTags).join(<Join>[
      innerJoin(_db.tags, _db.tags.tagId.equalsExp(_db.mediaItemTags.tagId)),
    ])..where(_db.mediaItemTags.itemId.equals(itemId))).get();

    return rows
        .map(
          (row) => TagWithId(
            tagId: row.readTable(_db.tags).tagId,
            tag: model.Tag(
              name: row.readTable(_db.tags).name,
              category: _intToCategory(row.readTable(_db.tags).category),
            ),
          ),
        )
        .toList(growable: false);
  }

  Future<Map<String, List<String>>> getTagNamesByItemIds(
    List<String> itemIds,
  ) async {
    final result = <String, List<String>>{};
    if (itemIds.isEmpty) {
      return result;
    }

    const chunkSize = 800;
    for (var index = 0; index < itemIds.length; index += chunkSize) {
      final chunk = itemIds.sublist(
        index,
        (index + chunkSize) > itemIds.length
            ? itemIds.length
            : (index + chunkSize),
      );

      final rows = await (_db.select(_db.mediaItemTags).join(<Join>[
        innerJoin(_db.tags, _db.tags.tagId.equalsExp(_db.mediaItemTags.tagId)),
      ])..where(_db.mediaItemTags.itemId.isIn(chunk))).get();

      for (final row in rows) {
        final link = row.readTable(_db.mediaItemTags);
        final tag = row.readTable(_db.tags);
        (result[link.itemId] ??= <String>[]).add(tag.name);
      }
    }

    return result;
  }

  Future<List<String>> findItemIdsByTag({
    required String folderRaw,
    required model.TagCategory category,
    required String name,
    bool partial = false,
  }) async {
    final categoryValue = _categoryToInt(category);

    final query =
        _db.select(_db.mediaItems).join(<Join>[
            innerJoin(
              _db.mediaItemTags,
              _db.mediaItemTags.itemId.equalsExp(_db.mediaItems.id),
            ),
            innerJoin(
              _db.tags,
              _db.tags.tagId.equalsExp(_db.mediaItemTags.tagId),
            ),
          ])
          ..where(_db.mediaItems.folderRaw.equals(folderRaw))
          ..where(_db.tags.category.equals(categoryValue));

    if (partial) {
      query.where(
        _db.tags.name.like('%${_escapeLike(name)}%', escapeChar: r'\'),
      );
    } else {
      query.where(_db.tags.name.equals(name));
    }

    final rows = await query.get();
    final ids = <String>{};
    for (final row in rows) {
      ids.add(row.readTable(_db.mediaItems).id);
    }
    return ids.toList(growable: false);
  }

  Future<List<TagWithId>> listTagMasterByCategory(
    model.TagCategory category, {
    String? contains,
    int limit = 200,
  }) async {
    final categoryValue = _categoryToInt(category);
    final query = _db.select(_db.tags)
      ..where((table) => table.category.equals(categoryValue))
      ..orderBy([(table) => OrderingTerm.asc(table.name)])
      ..limit(limit);

    if (contains != null && contains.trim().isNotEmpty) {
      query.where(
        (table) => table.name.like(
          '%${_escapeLike(contains.trim())}%',
          escapeChar: r'\',
        ),
      );
    }

    final rows = await query.get();
    return rows
        .map(
          (row) => TagWithId(
            tagId: row.tagId,
            tag: model.Tag(
              name: row.name,
              category: _intToCategory(row.category),
            ),
          ),
        )
        .toList(growable: false);
  }

  Future<List<model.Tag>> listTagsByCategory(model.TagCategory category) async {
    final categoryValue = _categoryToInt(category);
    final rows = await (_db.select(
      _db.tags,
    )..where((table) => table.category.equals(categoryValue))).get();

    final seen = <String>{};
    final result = <model.Tag>[];

    for (final row in rows) {
      final key = '${row.category}:${row.name}';
      if (seen.add(key)) {
        result.add(
          model.Tag(name: row.name, category: _intToCategory(row.category)),
        );
      }
    }
    return result;
  }

  Future<List<media.MediaItem>> listStoredMediaItems() async {
    final rows = await (_db.select(
      _db.mediaItems,
    )..orderBy([(table) => OrderingTerm.asc(table.displayName)])).get();

    return rows
        .map(
          (row) => media.MediaItem(
            id: row.id,
            folderRaw: row.folderRaw,
            displayName: row.displayName,
            kind: _kindFromInt(row.kind),
            modified: row.modifiedEpochMs == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(row.modifiedEpochMs!),
          ),
        )
        .toList(growable: false);
  }

  Future<List<media.MediaItem>> findMediaItemsByTagGlobal({
    required model.TagCategory category,
    required String name,
    bool partial = false,
  }) async {
    final categoryValue = _categoryToInt(category);

    final query = _db.select(_db.mediaItems).join(<Join>[
      innerJoin(
        _db.mediaItemTags,
        _db.mediaItemTags.itemId.equalsExp(_db.mediaItems.id),
      ),
      innerJoin(_db.tags, _db.tags.tagId.equalsExp(_db.mediaItemTags.tagId)),
    ])..where(_db.tags.category.equals(categoryValue));

    if (partial) {
      query.where(
        _db.tags.name.like('%${_escapeLike(name)}%', escapeChar: r'\'),
      );
    } else {
      query.where(_db.tags.name.equals(name));
    }

    final rows = await query.get();
    final seen = <String>{};
    final result = <media.MediaItem>[];

    for (final row in rows) {
      final item = row.readTable(_db.mediaItems);
      if (!seen.add(item.id)) {
        continue;
      }

      result.add(
        media.MediaItem(
          id: item.id,
          folderRaw: item.folderRaw,
          displayName: item.displayName,
          kind: _kindFromInt(item.kind),
          modified: item.modifiedEpochMs == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(item.modifiedEpochMs!),
        ),
      );
    }
    return result;
  }

  Future<Map<String, String>> organizeAppLibrary({
    required String libraryRoot,
  }) async {
    final moved = <String, String>{};
    final items =
        await (_db.select(_db.mediaItems)..where(
              (table) => table.id.like(
                '${_escapeLike(libraryRoot)}%',
                escapeChar: r'\',
              ),
            ))
            .get();

    for (final item in items) {
      if (item.id.startsWith('content://')) {
        continue;
      }

      final tags = await listTagsForItem(item.id);
      final artistTags = _tagsForCategory(tags, model.TagCategory.artist);
      final series = _pickFirst(tags, model.TagCategory.series);

      final destinationDir = _calcLibraryDestDir(
        libraryRoot: libraryRoot,
        artistTags: artistTags,
        series: series,
      );

      final sourcePath = item.id;
      final fileName = p.basename(sourcePath);
      var targetPath = p.join(destinationDir, fileName);

      if (p.equals(p.normalize(sourcePath), p.normalize(targetPath))) {
        debugPrint(
          '[TAG-ORGANIZE] no file move required; db only path=$sourcePath',
        );
        continue;
      }

      try {
        await Directory(destinationDir).create(recursive: true);

        final sourceType = await FileSystemEntity.type(
          sourcePath,
          followLinks: false,
        );
        if (sourceType == FileSystemEntityType.notFound) {
          continue;
        }

        final conflict = await LocalPathOperationService.checkNameConflict(
          sourcePath: sourcePath,
          targetPath: targetPath,
        );
        if (conflict == LocalPathConflictResult.sameFile) {
          debugPrint(
            '[TAG-ORGANIZE] no file move required; db only path=$sourcePath',
          );
          continue;
        }
        if (conflict == LocalPathConflictResult.duplicateName) {
          final replacementPath = _resolveAvailableFilePath(targetPath);
          debugPrint(
            '[TAG-ORGANIZE] renamed duplicate target source=$sourcePath '
            'target=$targetPath replacement=$replacementPath',
          );
          targetPath = replacementPath;
        }

        final movedFile = await LocalPathOperationService.moveItem(
          sourcePath: sourcePath,
          targetPath: targetPath,
          isDirectory: sourceType == FileSystemEntityType.directory,
          logPrefix: 'TAG-ORGANIZE',
        );
        if (!movedFile) {
          continue;
        }

        await _db.transaction(() async {
          final targetFileName = p.basename(targetPath);
          await _moveMediaItemRecord(
            beforeId: sourcePath,
            after: media.MediaItem(
              id: targetPath,
              folderRaw: p.dirname(targetPath),
              displayName: targetFileName,
              kind: _kindFromInt(item.kind),
              modified: item.modifiedEpochMs == null
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch(item.modifiedEpochMs!),
            ),
          );
        });
        await _removeEmptyAncestorDirs(
          startDir: p.dirname(sourcePath),
          stopAt: libraryRoot,
        );

        moved[sourcePath] = targetPath;
      } catch (error, stackTrace) {
        debugPrint(
          '[TAG-ORGANIZE] blocked source=$sourcePath target=$targetPath reason=$error',
        );
        debugPrintStack(label: '[TAG-ORGANIZE] stack', stackTrace: stackTrace);
      }
    }

    await _removeEmptyLegacyAuthorDirs(libraryRoot);

    return moved;
  }

  TagWithId? _pickFirst(List<TagWithId> tags, model.TagCategory category) {
    for (final entry in tags) {
      if (entry.tag.category == category && entry.tag.name.trim().isNotEmpty) {
        return entry;
      }
    }
    return null;
  }

  List<TagWithId> _tagsForCategory(
    List<TagWithId> tags,
    model.TagCategory category,
  ) {
    return tags
        .where(
          (entry) =>
              entry.tag.category == category &&
              entry.tag.name.trim().isNotEmpty,
        )
        .toList(growable: false);
  }

  String _calcLibraryDestDir({
    required String libraryRoot,
    required List<TagWithId> artistTags,
    TagWithId? series,
  }) {
    String safe(String input) => _sanitizeDirName(input);
    const authorDir = '\u4f5c\u8005';
    const seriesDir = '\u30b7\u30ea\u30fc\u30ba';
    const unknownDir = '\u4e0d\u660e';

    if (artistTags.length == 1) {
      return p.join(libraryRoot, authorDir, safe(artistTags.first.tag.name));
    }

    if (series != null) {
      return p.join(libraryRoot, seriesDir, safe(series.tag.name));
    }

    return p.join(libraryRoot, unknownDir);
  }

  String _sanitizeDirName(String input) {
    var value = input.trim();
    if (value.isEmpty) {
      return '_';
    }

    value = value.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    value = value.replaceAll(RegExp(r'[\x00-\x1F]'), '_');
    value = value.replaceAll(RegExp(r'[\. ]+$'), '');
    return value.isEmpty ? '_' : value;
  }

  String _resolveAvailableFilePath(String targetPath) {
    final normalizedTarget = p.normalize(targetPath);
    final parentDir = p.dirname(normalizedTarget);
    final extension = p.extension(normalizedTarget);
    final stem = p.basenameWithoutExtension(normalizedTarget);

    var candidate = normalizedTarget;
    var counter = 2;
    while (FileSystemEntity.typeSync(candidate) !=
        FileSystemEntityType.notFound) {
      candidate = p.join(parentDir, '$stem ($counter)$extension');
      counter++;
    }

    return p.normalize(candidate);
  }

  Future<void> _removeEmptyAncestorDirs({
    required String startDir,
    required String stopAt,
  }) async {
    final normalizedStop = p.normalize(stopAt);
    var current = p.normalize(startDir);
    while (!p.equals(current, normalizedStop) &&
        p.isWithin(normalizedStop, current)) {
      final removed = await _removeEmptyDirIfPossible(current);
      if (!removed) {
        break;
      }
      final parent = p.dirname(current);
      if (p.equals(parent, current)) {
        break;
      }
      current = parent;
    }
  }

  Future<bool> _removeEmptyDirIfPossible(String dirPath) async {
    try {
      final dir = Directory(dirPath);
      if (!await dir.exists()) {
        return false;
      }
      final isEmpty = await dir.list(followLinks: false).isEmpty;
      if (!isEmpty) {
        return false;
      }
      await dir.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _removeEmptyLegacyAuthorDirs(String libraryRoot) async {
    final legacyRoot = p.join(libraryRoot, '\u4f5c\u8005\u5225');
    final legacyDir = Directory(legacyRoot);
    if (!await legacyDir.exists()) {
      return;
    }

    final dirs = <String>[];
    await for (final entity in legacyDir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is Directory) {
        dirs.add(entity.path);
      }
    }
    dirs.sort((a, b) => p.normalize(b).length.compareTo(p.normalize(a).length));
    for (final dirPath in dirs) {
      await _removeEmptyDirIfPossible(dirPath);
    }
    await _removeEmptyDirIfPossible(legacyRoot);
  }

  bool _isPathWithinPrefix(String value, String prefix) {
    final normalizedValue = p.normalize(value);
    if (p.equals(normalizedValue, prefix)) {
      return true;
    }
    return p.isWithin(prefix, normalizedValue);
  }

  String _replacePathPrefix(
    String value,
    String beforePrefix,
    String afterPrefix,
  ) {
    final normalizedValue = p.normalize(value);
    if (p.equals(normalizedValue, beforePrefix)) {
      return afterPrefix;
    }

    final relative = p.relative(normalizedValue, from: beforePrefix);
    if (relative == '.') {
      return afterPrefix;
    }
    return p.normalize(p.join(afterPrefix, relative));
  }

  String _escapeLike(String value) {
    return value
        .replaceAll(r'\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
  }

  Future<void> _moveMediaItemRecord({
    required String beforeId,
    required media.MediaItem after,
  }) async {
    await _db
        .into(_db.mediaItems)
        .insertOnConflictUpdate(
          db.MediaItemsCompanion.insert(
            id: after.id,
            folderRaw: after.folderRaw,
            displayName: after.displayName,
            kind: _kindToInt(after.kind),
            modifiedEpochMs: Value(after.modified?.millisecondsSinceEpoch),
          ),
        );

    if (beforeId == after.id) {
      return;
    }

    await _db.customStatement(
      'INSERT OR IGNORE INTO media_item_tags (item_id, tag_id) '
      'SELECT ?, tag_id FROM media_item_tags WHERE item_id = ?',
      <Object?>[after.id, beforeId],
    );
    await (_db.delete(
      _db.mediaItemTags,
    )..where((table) => table.itemId.equals(beforeId))).go();
    await (_db.delete(
      _db.mediaItems,
    )..where((table) => table.id.equals(beforeId))).go();
  }
}
