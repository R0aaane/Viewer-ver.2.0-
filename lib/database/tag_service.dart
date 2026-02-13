import 'package:drift/drift.dart';
import '../models/mediaItem.dart' as m;
import '../models/tag.dart' as model;
import 'app_db.dart' as db;

class TagWithId { 
  final int tagId;
  final model.Tag tag;
  const TagWithId({required this.tagId, required this.tag});
}

class TagService {
  final db.AppDb _db;
  TagService(this._db);

  int _kindToInt(m.MediaKind kind) => kind == m.MediaKind.image ? 0 : 1;

  int _categoryToInt(model.TagCategory c) {
    switch (c) {
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

  model.TagCategory _intToCategory(int v) {
    final e = db.TagCategoryDb.values[v];
    switch (e) {
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

  Future<void> upsertMediaItem(m.MediaItem item) async {
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
    final cat = _categoryToInt(tag.category);

    final existing = await (_db.select(_db.tags)
          ..where((t) => t.name.equals(tag.name) & t.category.equals(cat)))
        .getSingleOrNull();

    if (existing != null) return existing.tagId;

    return _db.into(_db.tags).insert(
          db.TagsCompanion.insert(name: tag.name, category: cat),
        );
  }

  Future<void> addTagToItem(m.MediaItem item, model.Tag tag) async {
    await upsertMediaItem(item);
    final tagId = await ensureTagId(tag);

    await _db.into(_db.mediaItemTags).insert(
          db.MediaItemTagsCompanion.insert(itemId: item.id, tagId: tagId),
          mode: InsertMode.insertOrIgnore,
        );
  }

  Future<List<TagWithId>> listTagsForItem(String itemId) async {
    final rows = await (_db.select(_db.mediaItemTags).join([
      innerJoin(_db.tags, _db.tags.tagId.equalsExp(_db.mediaItemTags.tagId)),
    ])
          ..where(_db.mediaItemTags.itemId.equals(itemId)))
        .get();

    return rows.map((r) {
      final t = r.readTable(_db.tags);
      return TagWithId(
        tagId: t.tagId,
        tag: model.Tag(name: t.name, category: _intToCategory(t.category)),
      );
    }).toList(growable: false);
  }

  Future<List<String>> findItemIdsByTag({
    required String folderRaw,
    required model.TagCategory category,
    required String name,
    bool partial = false,
  }) async {
    final cat = _categoryToInt(category);

    final q = _db.select(_db.mediaItems).join([
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
      ..where(_db.tags.category.equals(cat));

    if (partial) {
      q.where(_db.tags.name.like('%$name%'));
    } else {
      q.where(_db.tags.name.equals(name));
    }

    final rows = await q.get();

    final ids = <String>{};
    for (final r in rows) {
      ids.add(r.readTable(_db.mediaItems).id);
    }
    return ids.toList(growable: false);
  }

  Future<void> removeTagFromItem(String itemId, int tagId) async {
  await (_db.delete(_db.mediaItemTags)
        ..where((x) => x.itemId.equals(itemId) & x.tagId.equals(tagId)))
      .go();
  }
  /// カテゴリ内のタグ候補（マスター）を一覧取得
  Future<List<TagWithId>> listTagMasterByCategory(
    model.TagCategory category, {
    String? contains, // 絞り込み用（任意）
    int limit = 200,
  }) async {
    final cat = _categoryToInt(category);
  
    final q = _db.select(_db.tags)
      ..where((t) => t.category.equals(cat))
      ..orderBy([(t) => OrderingTerm.asc(t.name)])
      ..limit(limit);
  
    if (contains != null && contains.trim().isNotEmpty) {
      final s = contains.trim();
      q.where((t) => t.name.like('%$s%'));
    }
  
    final rows = await q.get();
    return rows
        .map((t) => TagWithId(tagId: t.tagId, tag: model.Tag(name: t.name, category: _intToCategory(t.category))))
        .toList(growable: false);
  }
  
  /// マスタータグを削除（使っているアイテムがあっても消したい場合用）
  Future<void> deleteTagMaster(int tagId) async {
    await _db.transaction(() async {
      await (_db.delete(_db.mediaItemTags)..where((x) => x.tagId.equals(tagId))).go();
      await (_db.delete(_db.tags)..where((x) => x.tagId.equals(tagId))).go();
    });
  }


}


