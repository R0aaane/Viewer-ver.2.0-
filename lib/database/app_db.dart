import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import '../services/app_storage_paths.dart';

part 'app_db.g.dart';

enum TagCategoryDb { artist, series, mediaType, character, free }

// MediaItem の定義はここから
@DataClassName('DbMediaItem')
class MediaItems extends Table {
  TextColumn get id => text()(); // Windows: full path / Android: document Uri
  TextColumn get folderRaw =>
      text()(); // Windows: parent path / Android: treeUri
  TextColumn get displayName => text()();
  IntColumn get kind => integer()(); // 0=image 1=pdf
  IntColumn get modifiedEpochMs => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

// Tagの定義はここから
@DataClassName('DbTag')
class Tags extends Table {
  IntColumn get tagId => integer().autoIncrement()();
  TextColumn get name => text()();
  IntColumn get category => integer()(); // TagCategoryDb index

  @override
  List<String> get customConstraints => ['UNIQUE(name, category)'];
}

@DataClassName('DbMediaItemTag')
class MediaItemTags extends Table {
  TextColumn get itemId => text().references(MediaItems, #id)();
  IntColumn get tagId => integer().references(Tags, #tagId)();

  @override
  Set<Column> get primaryKey => {itemId, tagId};
}

//  フォルダ一覧インデックス用
enum FolderEntryKindDb {
  folder, // 0
  image, // 1
  pdf, // 2
  epub, // 3
}

@DataClassName('DbFolderIndex')
class FolderIndexes extends Table {
  TextColumn get folderRaw => text()(); // content:// treeUri or fs path
  IntColumn get scannedAtEpochMs => integer()(); // last scan time
  IntColumn get totalCount => integer()(); // entries count

  @override
  Set<Column> get primaryKey => {folderRaw};
}

@DataClassName('DbFolderEntry')
class FolderEntries extends Table {
  TextColumn get folderRaw => text()(); // parent folder raw
  TextColumn get entryId => text()(); // SAF documentUri / fs full path
  TextColumn get displayName => text()(); // name shown
  IntColumn get kind => integer()(); // FolderEntryKindDb index
  IntColumn get modifiedEpochMs => integer().nullable()();

  // sort最適化（小文字化したキーを持つ）
  TextColumn get sortName => text()();

  @override
  Set<Column> get primaryKey => {folderRaw, entryId};
}

@DriftDatabase(
  tables: [MediaItems, Tags, MediaItemTags, FolderIndexes, FolderEntries],
)
class AppDb extends _$AppDb {
  AppDb() : super(_openConnection());

  @override
  int get schemaVersion => 3;

  // 将来のマイグレーション用
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await _createIndexes();
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.createTable(folderIndexes);
        await m.createTable(folderEntries);
      }
      if (from < 3) {
        await _createIndexes();
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
      await customStatement('PRAGMA journal_mode = WAL');
      await customStatement('PRAGMA busy_timeout = 5000');
    },
  );

  Future<void> _createIndexes() async {
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_media_items_folder_raw '
      'ON media_items(folder_raw)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_tags_category_name '
      'ON tags(category, name)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_media_item_tags_item_id '
      'ON media_item_tags(item_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_media_item_tags_tag_id '
      'ON media_item_tags(tag_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_folder_entries_folder_sort '
      'ON folder_entries(folder_raw, sort_name)',
    );
  }

  Future<void> backupToFile(File target) async {
    await target.parent.create(recursive: true);
    if (await target.exists()) {
      await target.delete();
    }
    await customStatement('VACUUM INTO ?', <Object?>[target.path]);
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final File file = await getAppDatabaseFile();
    return NativeDatabase(file);
  });
}
