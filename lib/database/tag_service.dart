import 'package:drift/drift.dart';
import '../models/mediaItem.dart' as m;
import 'dart:io';
import 'package:path/path.dart' as p;
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
    final cat = _categoryToInt(tag.category);

    final existing =
        await (_db.select(_db.tags)
              ..where((t) => t.name.equals(tag.name) & t.category.equals(cat)))
            .getSingleOrNull();

    if (existing != null) return existing.tagId;

    return _db
        .into(_db.tags)
        .insert(db.TagsCompanion.insert(name: tag.name, category: cat));
  }

  Future<void> addTagToItem(m.MediaItem item, model.Tag tag) async {
    await upsertMediaItem(item);
    final tagId = await ensureTagId(tag);

    await _db
        .into(_db.mediaItemTags)
        .insert(
          db.MediaItemTagsCompanion.insert(itemId: item.id, tagId: tagId),
          mode: InsertMode.insertOrIgnore,
        );
  }

  Future<void> deleteItemsByIds(List<String> ids) async {
    if (ids.isEmpty) return;

    await _db.transaction(() async {
      await (_db.delete(_db.mediaItemTags)..where((t) => t.itemId.isIn(ids))).go();
      await (_db.delete(_db.mediaItems)..where((t) => t.id.isIn(ids))).go();
    });
  }

  Future<List<TagWithId>> listTagsForItem(String itemId) async {
    final rows = await (_db.select(_db.mediaItemTags).join([
      innerJoin(_db.tags, _db.tags.tagId.equalsExp(_db.mediaItemTags.tagId)),
    ])..where(_db.mediaItemTags.itemId.equals(itemId))).get();

    return rows
        .map((r) {
          final t = r.readTable(_db.tags);
          return TagWithId(
            tagId: t.tagId,
            tag: model.Tag(name: t.name, category: _intToCategory(t.category)),
          );
        })
        .toList(growable: false);
  }

  // 複数 itemId のタグ名一覧をまとめて取得（Home検索用）
  Future<Map<String, List<String>>> getTagNamesByItemIds(
    List<String> itemIds,
  ) async {
    final result = <String, List<String>>{};
    if (itemIds.isEmpty) return result;

    // SQLite の IN 句の上限対策（だいたい 900 くらいで刻む）
    const chunkSize = 800;

    for (int i = 0; i < itemIds.length; i += chunkSize) {
      final chunk = itemIds.sublist(
        i,
        (i + chunkSize) > itemIds.length ? itemIds.length : (i + chunkSize),
      );

      final q = _db.select(_db.mediaItemTags).join([
        innerJoin(_db.tags, _db.tags.tagId.equalsExp(_db.mediaItemTags.tagId)),
      ])..where(_db.mediaItemTags.itemId.isIn(chunk));

      final rows = await q.get();

      for (final r in rows) {
        final link = r.readTable(_db.mediaItemTags);
        final t = r.readTable(_db.tags);
        (result[link.itemId] ??= <String>[]).add(t.name);
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
    final cat = _categoryToInt(category);

    final q =
        _db.select(_db.mediaItems).join([
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
    await (_db.delete(
      _db.mediaItemTags,
    )..where((x) => x.itemId.equals(itemId) & x.tagId.equals(tagId))).go();
  }

  /// カテゴリ内のタグ候補（マスター）を一覧取得
  Future<List<TagWithId>> listTagMasterByCategory(
    model.TagCategory category, {
    String? contains,
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
        .map(
          (t) => TagWithId(
            tagId: t.tagId,
            tag: model.Tag(name: t.name, category: _intToCategory(t.category)),
          ),
        )
        .toList(growable: false);
  }

  // 表示中など「複数アイテムに同じタグを一括付与」する
  Future<void> addTagToItems(List<m.MediaItem> items, model.Tag tag) async {
    if (items.isEmpty) return;

    final tagId = await ensureTagId(tag);

    // drift batch で高速に upsert + link insert(orIgnore)
    await _db.batch((b) {
      b.insertAllOnConflictUpdate(
        _db.mediaItems,
        items
            .map((it) {
              return db.MediaItemsCompanion.insert(
                id: it.id,
                folderRaw: it.folderRaw,
                displayName: it.displayName,
                kind: _kindToInt(it.kind),
                modifiedEpochMs: Value(it.modified?.millisecondsSinceEpoch),
              );
            })
            .toList(growable: false),
      );

      // link insert (ignore duplicates)
      b.insertAll(
        _db.mediaItemTags,
        items
            .map((it) {
              return db.MediaItemTagsCompanion.insert(
                itemId: it.id,
                tagId: tagId,
              );
            })
            .toList(growable: false),
        mode: InsertMode.insertOrIgnore,
      );
    });
  }

  // ----------------------------
  // カテゴリ別タグ一覧（例: artist）
  Future<List<model.Tag>> listTagsByCategory(model.TagCategory category) async {
    final cat = _categoryToInt(category);

    final rows = await (_db.select(
      _db.tags,
    )..where((t) => t.category.equals(cat))).get();

    // 重複排除（念のため）
    final seen = <String>{};
    final out = <model.Tag>[];
    for (final r in rows) {
      final key = '${r.category}:${r.name}';
      if (seen.add(key)) {
        out.add(model.Tag(name: r.name, category: _intToCategory(r.category)));
      }
    }
    return out;
  }

  // タグ（カテゴリ+名前）に紐づく MediaItem をDBから復元して返す
  Future<List<m.MediaItem>> findMediaItemsByTagGlobal({
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
      innerJoin(_db.tags, _db.tags.tagId.equalsExp(_db.mediaItemTags.tagId)),
    ])..where(_db.tags.category.equals(cat));

    if (partial) {
      q.where(_db.tags.name.like('%$name%'));
    } else {
      q.where(_db.tags.name.equals(name));
    }

    final rows = await q.get();

    // 重複を排除しつつ復元
    final seen = <String>{};
    final out = <m.MediaItem>[];

    for (final r in rows) {
      final mi = r.readTable(_db.mediaItems);
      if (!seen.add(mi.id)) continue;

      out.add(
        m.MediaItem(
          id: mi.id,
          folderRaw: mi.folderRaw,
          displayName: mi.displayName,
          kind: (mi.kind == 0) ? m.MediaKind.image : m.MediaKind.pdf,
          modified: (mi.modifiedEpochMs == null)
              ? null
              : DateTime.fromMillisecondsSinceEpoch(mi.modifiedEpochMs!),
        ),
      );
    }
    return out;
  }

  //保管庫の整理用
  Future<Map<String, String>> organizeAppLibrary({
    required String libraryRoot,
  }) async {
    final moved = <String, String>{};

    // libraryRoot 配下の MediaItems をDBから拾う（id が file path のもの前提）
    final items = await (_db.select(
      _db.mediaItems,
    )..where((m) => m.id.like('$libraryRoot%'))).get();

    for (final it in items) {
      // SAF Uriは対象外（保管庫は file path の想定）
      if (it.id.startsWith('content://')) continue;

      final tags = await listTagsForItem(it.id);
      final artist = _pickFirst(tags, model.TagCategory.artist);
      final series = _pickFirst(tags, model.TagCategory.series);

      // タグが無いなら移動しない（library直下でOK）
      if (artist == null && series == null) continue;

      final destDir = _calcLibraryDestDir(
        libraryRoot: libraryRoot,
        artist: artist,
        series: series,
      );

      final srcPath = it.id;
      final fileName = p.basename(srcPath);
      final targetPath = _uniquePath(destDir, fileName);

      // 既に期待位置なら何もしない
      if (p.equals(p.normalize(srcPath), p.normalize(targetPath))) continue;

      try {
        await Directory(destDir).create(recursive: true);

        // move (rename) → 失敗したら copy+delete
        final srcFile = File(srcPath);
        if (!await srcFile.exists()) continue;

        try {
          await srcFile.rename(targetPath);
        } catch (_) {
          await srcFile.copy(targetPath);
          await srcFile.delete();
        }

        // DB: oldId -> newId に付け替え
        await _db.transaction(() async {
          // new mediaItems row
          await _db
              .into(_db.mediaItems)
              .insertOnConflictUpdate(
                db.MediaItemsCompanion.insert(
                  id: targetPath,
                  folderRaw: p.dirname(targetPath),
                  displayName: fileName,
                  kind: it.kind,
                  modifiedEpochMs: Value(it.modifiedEpochMs),
                ),
              );

          // mediaItemTags の itemId を更新
          await _db.customUpdate(
            'UPDATE media_item_tags SET item_id = ? WHERE item_id = ?',
            variables: [
              Variable<String>(targetPath),
              Variable<String>(srcPath),
            ],
            updates: {_db.mediaItemTags},
          );

          // old mediaItems row delete
          await (_db.delete(
            _db.mediaItems,
          )..where((m) => m.id.equals(srcPath))).go();
        });

        moved[srcPath] = targetPath;
      } catch (_) {
        // 1件失敗しても続行
      }
    }

    return moved;
  }

  TagWithId? _pickFirst(List<TagWithId> tags, model.TagCategory cat) {
    for (final t in tags) {
      if (t.tag.category == cat) return t;
    }
    return null;
  }

  String _calcLibraryDestDir({
    required String libraryRoot,
    TagWithId? artist,
    TagWithId? series,
  }) {
    String safe(String s) => _sanitizeDirName(s);

    if (artist != null) {
      final a = safe(artist.tag.name);
      if (series != null) {
        final s = safe(series.tag.name);
        return p.join(libraryRoot, '作者', a, s);
      }
      return p.join(libraryRoot, '作者', a);
    }

    // artist無しで series だけある場合は “シリーズ” 配下に置く
    if (series != null) {
      final s = safe(series.tag.name);
      return p.join(libraryRoot, 'シリーズ', s);
    }

    return libraryRoot;
  }

  String _sanitizeDirName(String input) {
    var s = input.trim();
    if (s.isEmpty) return '_';

    // Windows NG文字 + パス区切り等を置換
    s = s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    // 制御文字も排除
    s = s.replaceAll(RegExp(r'[\x00-\x1F]'), '_');
    // 末尾のドット/スペースはWindowsで問題になりやすい
    s = s.replaceAll(RegExp(r'[\. ]+$'), '');
    if (s.isEmpty) return '_';
    return s;
  }

  String _uniquePath(String dir, String fileName) {
    final base = p.basenameWithoutExtension(fileName);
    final ext = p.extension(fileName);

    var candidate = p.join(dir, fileName);
    var n = 1;
    while (File(candidate).existsSync()) {
      candidate = p.join(dir, '$base ($n)$ext');
      n++;
      if (n > 999) {
        candidate = p.join(
          dir,
          '${base}_${DateTime.now().millisecondsSinceEpoch}$ext',
        );
        break;
      }
    }
    return candidate;
  }
}
