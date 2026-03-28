import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../models/mediaItem.dart' as media;
import '../models/tag.dart' as model;
import '../models/tag_with_id.dart';
import 'app_db.dart' as db;

class LocalTagStore {
  final db.AppDb _db;

  LocalTagStore(this._db);

  int _kindToInt(media.MediaKind kind) => kind == media.MediaKind.image ? 0 : 1;

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
    await _db.into(_db.mediaItems).insertOnConflictUpdate(
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

    final existing = await (_db.select(_db.tags)
          ..where((table) => table.name.equals(tag.name) & table.category.equals(category)))
        .getSingleOrNull();

    if (existing != null) {
      return existing.tagId;
    }

    return _db
        .into(_db.tags)
        .insert(db.TagsCompanion.insert(name: tag.name, category: category));
  }

  Future<void> addTagToItem(media.MediaItem item, model.Tag tag) async {
    await upsertMediaItem(item);
    final tagId = await ensureTagId(tag);

    await _db.into(_db.mediaItemTags).insert(
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
    await (_db.delete(_db.mediaItemTags)
          ..where((table) => table.itemId.equals(itemId) & table.tagId.equals(tagId)))
        .go();
  }

  Future<void> deleteItemsByIds(List<String> ids) async {
    if (ids.isEmpty) {
      return;
    }

    await _db.transaction(() async {
      await (_db.delete(_db.mediaItemTags)..where((table) => table.itemId.isIn(ids))).go();
      await (_db.delete(_db.mediaItems)..where((table) => table.id.isIn(ids))).go();
    });
  }

  Future<void> deleteItemsUnderPathPrefix(String prefix) async {
    final like = '$prefix%';
    final rows = await (_db.select(_db.mediaItems)..where((table) => table.id.like(like))).get();
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
      await _db.into(_db.mediaItems).insertOnConflictUpdate(
            db.MediaItemsCompanion.insert(
              id: after.id,
              folderRaw: after.folderRaw,
              displayName: after.displayName,
              kind: _kindToInt(after.kind),
              modifiedEpochMs: Value(after.modified?.millisecondsSinceEpoch),
            ),
          );

      await _db.customUpdate(
        'UPDATE media_item_tags SET item_id = ? WHERE item_id = ?',
        variables: [
          Variable<String>(after.id),
          Variable<String>(before.id),
        ],
        updates: {_db.mediaItemTags},
      );

      await (_db.delete(_db.mediaItems)..where((table) => table.id.equals(before.id))).go();
    });
  }

  Future<List<TagWithId>> listTagsForItem(String itemId) async {
    final rows = await (_db.select(_db.mediaItemTags).join(<Join>[
      innerJoin(_db.tags, _db.tags.tagId.equalsExp(_db.mediaItemTags.tagId)),
    ])..where(_db.mediaItemTags.itemId.equals(itemId)))
        .get();

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

  Future<Map<String, List<String>>> getTagNamesByItemIds(List<String> itemIds) async {
    final result = <String, List<String>>{};
    if (itemIds.isEmpty) {
      return result;
    }

    const chunkSize = 800;
    for (var index = 0; index < itemIds.length; index += chunkSize) {
      final chunk = itemIds.sublist(
        index,
        (index + chunkSize) > itemIds.length ? itemIds.length : (index + chunkSize),
      );

      final rows = await (_db.select(_db.mediaItemTags).join(<Join>[
        innerJoin(_db.tags, _db.tags.tagId.equalsExp(_db.mediaItemTags.tagId)),
      ])..where(_db.mediaItemTags.itemId.isIn(chunk)))
          .get();

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

    final query = _db.select(_db.mediaItems).join(<Join>[
      innerJoin(_db.mediaItemTags, _db.mediaItemTags.itemId.equalsExp(_db.mediaItems.id)),
      innerJoin(_db.tags, _db.tags.tagId.equalsExp(_db.mediaItemTags.tagId)),
    ])
      ..where(_db.mediaItems.folderRaw.equals(folderRaw))
      ..where(_db.tags.category.equals(categoryValue));

    if (partial) {
      query.where(_db.tags.name.like('%$name%'));
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
      query.where((table) => table.name.like('%${contains.trim()}%'));
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
    final rows =
        await (_db.select(_db.tags)..where((table) => table.category.equals(categoryValue))).get();

    final seen = <String>{};
    final result = <model.Tag>[];

    for (final row in rows) {
      final key = '${row.category}:${row.name}';
      if (seen.add(key)) {
        result.add(
          model.Tag(
            name: row.name,
            category: _intToCategory(row.category),
          ),
        );
      }
    }
    return result;
  }

  Future<List<media.MediaItem>> listStoredMediaItems() async {
    final rows = await (_db.select(_db.mediaItems)
          ..orderBy([(table) => OrderingTerm.asc(table.displayName)]))
        .get();

    return rows
        .map(
          (row) => media.MediaItem(
            id: row.id,
            folderRaw: row.folderRaw,
            displayName: row.displayName,
            kind: row.kind == 0 ? media.MediaKind.image : media.MediaKind.pdf,
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
      innerJoin(_db.mediaItemTags, _db.mediaItemTags.itemId.equalsExp(_db.mediaItems.id)),
      innerJoin(_db.tags, _db.tags.tagId.equalsExp(_db.mediaItemTags.tagId)),
    ])..where(_db.tags.category.equals(categoryValue));

    if (partial) {
      query.where(_db.tags.name.like('%$name%'));
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
          kind: item.kind == 0 ? media.MediaKind.image : media.MediaKind.pdf,
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
    final items = await (_db.select(_db.mediaItems)
          ..where((table) => table.id.like('$libraryRoot%')))
        .get();

    for (final item in items) {
      if (item.id.startsWith('content://')) {
        continue;
      }

      final tags = await listTagsForItem(item.id);
      final artist = _pickFirst(tags, model.TagCategory.artist);
      final series = _pickFirst(tags, model.TagCategory.series);

      if (artist == null && series == null) {
        continue;
      }

      final destinationDir = _calcLibraryDestDir(
        libraryRoot: libraryRoot,
        artist: artist,
        series: series,
      );

      final sourcePath = item.id;
      final fileName = p.basename(sourcePath);
      final targetPath = _uniquePath(destinationDir, fileName);

      if (p.equals(p.normalize(sourcePath), p.normalize(targetPath))) {
        continue;
      }

      try {
        await Directory(destinationDir).create(recursive: true);

        final sourceFile = File(sourcePath);
        if (!await sourceFile.exists()) {
          continue;
        }

        try {
          await sourceFile.rename(targetPath);
        } catch (_) {
          await sourceFile.copy(targetPath);
          await sourceFile.delete();
        }

        await _db.transaction(() async {
          await _db.into(_db.mediaItems).insertOnConflictUpdate(
                db.MediaItemsCompanion.insert(
                  id: targetPath,
                  folderRaw: p.dirname(targetPath),
                  displayName: fileName,
                  kind: item.kind,
                  modifiedEpochMs: Value(item.modifiedEpochMs),
                ),
              );

          await _db.customUpdate(
            'UPDATE media_item_tags SET item_id = ? WHERE item_id = ?',
            variables: [
              Variable<String>(targetPath),
              Variable<String>(sourcePath),
            ],
            updates: {_db.mediaItemTags},
          );

          await (_db.delete(_db.mediaItems)..where((table) => table.id.equals(sourcePath))).go();
        });

        moved[sourcePath] = targetPath;
      } catch (_) {
        // 続行
      }
    }

    return moved;
  }

  TagWithId? _pickFirst(List<TagWithId> tags, model.TagCategory category) {
    for (final entry in tags) {
      if (entry.tag.category == category) {
        return entry;
      }
    }
    return null;
  }

  String _calcLibraryDestDir({
    required String libraryRoot,
    TagWithId? artist,
    TagWithId? series,
  }) {
    String safe(String input) => _sanitizeDirName(input);

    if (artist != null) {
      final artistName = safe(artist.tag.name);
      if (series != null) {
        return p.join(libraryRoot, '作者別', artistName, safe(series.tag.name));
      }
      return p.join(libraryRoot, '作者別', artistName);
    }

    if (series != null) {
      return p.join(libraryRoot, 'シリーズ', safe(series.tag.name));
    }

    return libraryRoot;
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

  String _uniquePath(String dir, String fileName) {
    final base = p.basenameWithoutExtension(fileName);
    final extension = p.extension(fileName);

    var candidate = p.join(dir, fileName);
    var index = 1;
    while (File(candidate).existsSync()) {
      candidate = p.join(dir, '$base ($index)$extension');
      index++;
      if (index > 999) {
        return p.join(dir, '${base}_${DateTime.now().millisecondsSinceEpoch}$extension');
      }
    }
    return candidate;
  }
}
