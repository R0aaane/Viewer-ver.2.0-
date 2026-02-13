import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'app_db.g.dart';

/// TagCategory はあなたの models/tag.dart の enum と「順序を揃える」こと
enum TagCategoryDb {
  artist,
  series,
  mediaType,
  character,
  free,
}

// MediaItem の定義はここから
@DataClassName('DbMediaItem')
class MediaItems extends Table {
  TextColumn get id => text()(); // Windows: full path / Android: document Uri
  TextColumn get folderRaw => text()(); // Windows: parent path / Android: treeUri
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
  List<String> get customConstraints => [
        'UNIQUE(name, category)',
      ];
}

@DataClassName('DbMediaItemTag')
class MediaItemTags extends Table {
  TextColumn get itemId => text().references(MediaItems, #id)();
  IntColumn get tagId => integer().references(Tags, #tagId)();

  @override
  Set<Column> get primaryKey => {itemId, tagId};
}

@DriftDatabase(tables: [MediaItems, Tags, MediaItemTags])
class AppDb extends _$AppDb {
  AppDb() : super(_openConnection());

  @override
  int get schemaVersion => 1;

  // 将来のマイグレーション用
  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async => m.createAll(),
        onUpgrade: (m, from, to) async {
          // schemaVersion を上げたらここに追加
        },
      );
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final Directory dir = await getApplicationDocumentsDirectory();
    final File file = File(p.join(dir.path, 'media_viewer.sqlite'));
    return NativeDatabase(file);
  });
}
