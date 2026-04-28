import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pdf_viewer/database/app_db.dart';
import 'package:pdf_viewer/database/database_backup_service.dart';
import 'package:pdf_viewer/database/local_tag_store.dart';
import 'package:pdf_viewer/models/mediaItem.dart';
import 'package:pdf_viewer/models/tag.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PathProviderPlatform originalPathProvider;

  setUp(() {
    originalPathProvider = PathProviderPlatform.instance;
  });

  tearDown(() {
    PathProviderPlatform.instance = originalPathProvider;
  });

  test(
    'renameItem keeps tags when destination media record already exists',
    () async {
      final docsDir = await Directory.systemTemp.createTemp(
        'local-tag-store-rename',
      );
      addTearDown(() async {
        if (await docsDir.exists()) {
          await docsDir.delete(recursive: true);
        }
      });
      PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);

      final db = AppDb();
      addTearDown(db.close);
      final store = LocalTagStore(db);

      final libraryRoot = Directory(p.join(docsDir.path, 'library'));
      await libraryRoot.create(recursive: true);

      final beforePath = p.join(libraryRoot.path, 'source.pdf');
      await File(beforePath).writeAsBytes(const <int>[1, 2, 3]);
      final before = MediaItem(
        id: beforePath,
        displayName: 'source.pdf',
        kind: MediaKind.pdf,
        folderRaw: libraryRoot.path,
      );

      final afterFolder = Directory(p.join(libraryRoot.path, 'organized'));
      await afterFolder.create(recursive: true);
      final afterPath = p.join(afterFolder.path, 'source.pdf');
      final after = MediaItem(
        id: afterPath,
        displayName: 'source.pdf',
        kind: MediaKind.pdf,
        folderRaw: afterFolder.path,
      );

      await store.addTagToItem(
        before,
        const Tag(name: 'ArtistA', category: TagCategory.artist),
      );
      await store.addTagToItem(
        after,
        const Tag(name: 'SeriesB', category: TagCategory.series),
      );

      await store.renameItem(before, after);

      final tags = await store.listTagsForItem(after.id);
      expect(
        tags
            .map((entry) => '${entry.tag.category.name}:${entry.tag.name}')
            .toSet(),
        <String>{'artist:ArtistA', 'series:SeriesB'},
      );
      expect(await store.listTagsForItem(before.id), isEmpty);
      expect(
        await store.findMediaItemsByTagGlobal(
          category: TagCategory.artist,
          name: 'ArtistA',
        ),
        hasLength(1),
      );
      expect(
        (await store.findMediaItemsByTagGlobal(
          category: TagCategory.artist,
          name: 'ArtistA',
        )).single.id,
        after.id,
      );
    },
  );

  test('database creates query indexes', () async {
    final docsDir = await Directory.systemTemp.createTemp(
      'local-tag-store-indexes',
    );
    addTearDown(() async {
      if (await docsDir.exists()) {
        await docsDir.delete(recursive: true);
      }
    });
    PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);

    final db = AppDb();
    addTearDown(db.close);

    final rows = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'index'")
        .get();
    final names = rows.map((row) => row.read<String>('name')).toSet();

    expect(names, contains('idx_media_items_folder_raw'));
    expect(names, contains('idx_tags_category_name'));
    expect(names, contains('idx_media_item_tags_item_id'));
    expect(names, contains('idx_media_item_tags_tag_id'));
    expect(names, contains('idx_folder_entries_folder_sort'));
  });

  test('ensureTagId tolerates repeated concurrent inserts', () async {
    final docsDir = await Directory.systemTemp.createTemp(
      'local-tag-store-tags',
    );
    addTearDown(() async {
      if (await docsDir.exists()) {
        await docsDir.delete(recursive: true);
      }
    });
    PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);

    final db = AppDb();
    addTearDown(db.close);
    final store = LocalTagStore(db);

    final ids = await Future.wait(
      List<Future<int>>.generate(
        20,
        (_) => store.ensureTagId(
          const Tag(name: 'Same Tag', category: TagCategory.free),
        ),
      ),
    );

    expect(ids.toSet(), hasLength(1));
  });

  test('database backup exports a readable sqlite file', () async {
    final docsDir = await Directory.systemTemp.createTemp(
      'local-tag-store-backup',
    );
    addTearDown(() async {
      if (await docsDir.exists()) {
        await docsDir.delete(recursive: true);
      }
    });
    PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);

    final db = AppDb();
    addTearDown(db.close);
    final store = LocalTagStore(db);
    await store.ensureTagId(
      const Tag(name: 'Backup Tag', category: TagCategory.free),
    );

    final backup = await DatabaseBackupService.createBackupInAppStorage(db);
    expect(await File(backup.savedPath).exists(), isTrue);
    expect(backup.sizeBytes, greaterThan(0));
  });

  test(
    'partial tag search treats LIKE wildcards as literal characters',
    () async {
      final docsDir = await Directory.systemTemp.createTemp(
        'local-tag-store-like',
      );
      addTearDown(() async {
        if (await docsDir.exists()) {
          await docsDir.delete(recursive: true);
        }
      });
      PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);

      final db = AppDb();
      addTearDown(db.close);
      final store = LocalTagStore(db);

      final folder = p.join(docsDir.path, 'library');
      final percentItem = MediaItem(
        id: p.join(folder, 'percent.pdf'),
        displayName: 'percent.pdf',
        kind: MediaKind.pdf,
        folderRaw: folder,
      );
      final plainItem = MediaItem(
        id: p.join(folder, 'plain.pdf'),
        displayName: 'plain.pdf',
        kind: MediaKind.pdf,
        folderRaw: folder,
      );

      await store.addTagToItem(
        percentItem,
        const Tag(name: '50% off', category: TagCategory.free),
      );
      await store.addTagToItem(
        plainItem,
        const Tag(name: '50X off', category: TagCategory.free),
      );

      expect(
        await store.findItemIdsByTag(
          folderRaw: folder,
          category: TagCategory.free,
          name: '50%',
          partial: true,
        ),
        <String>[percentItem.id],
      );
    },
  );

  test(
    'deleteItemsUnderPathPrefix treats LIKE wildcards as literal characters',
    () async {
      final docsDir = await Directory.systemTemp.createTemp(
        'local-tag-store-prefix',
      );
      addTearDown(() async {
        if (await docsDir.exists()) {
          await docsDir.delete(recursive: true);
        }
      });
      PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);

      final db = AppDb();
      addTearDown(db.close);
      final store = LocalTagStore(db);

      final underPrefix = MediaItem(
        id: p.join(docsDir.path, 'a_1', 'inside.pdf'),
        displayName: 'inside.pdf',
        kind: MediaKind.pdf,
        folderRaw: p.join(docsDir.path, 'a_1'),
      );
      final outsidePrefix = MediaItem(
        id: p.join(docsDir.path, 'ab1', 'outside.pdf'),
        displayName: 'outside.pdf',
        kind: MediaKind.pdf,
        folderRaw: p.join(docsDir.path, 'ab1'),
      );

      await store.addTagToItem(
        underPrefix,
        const Tag(name: 'Inside', category: TagCategory.free),
      );
      await store.addTagToItem(
        outsidePrefix,
        const Tag(name: 'Outside', category: TagCategory.free),
      );

      await store.deleteItemsUnderPathPrefix(p.join(docsDir.path, 'a_1'));

      expect(await store.listTagsForItem(underPrefix.id), isEmpty);
      expect(await store.listTagsForItem(outsidePrefix.id), isNotEmpty);
    },
  );

  test('organizeAppLibrary keeps moved items searchable by tag', () async {
    final docsDir = await Directory.systemTemp.createTemp(
      'local-tag-store-organize',
    );
    addTearDown(() async {
      if (await docsDir.exists()) {
        await docsDir.delete(recursive: true);
      }
    });
    PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);

    final db = AppDb();
    addTearDown(db.close);
    final store = LocalTagStore(db);

    final libraryRoot = Directory(p.join(docsDir.path, 'library'));
    await libraryRoot.create(recursive: true);

    final sourcePath = p.join(libraryRoot.path, 'sample.pdf');
    await File(sourcePath).writeAsBytes(const <int>[9, 9, 9]);
    final source = MediaItem(
      id: sourcePath,
      displayName: 'sample.pdf',
      kind: MediaKind.pdf,
      folderRaw: libraryRoot.path,
    );

    await store.addTagToItem(
      source,
      const Tag(name: 'Todakenji', category: TagCategory.artist),
    );

    final moved = await store.organizeAppLibrary(libraryRoot: libraryRoot.path);
    final targetPath = moved[sourcePath];
    final expectedPath = p.join(
      libraryRoot.path,
      '\u4f5c\u8005',
      'Todakenji',
      'sample.pdf',
    );

    expect(targetPath, expectedPath);
    expect(await File(targetPath!).exists(), isTrue);
    expect(await store.listTagsForItem(targetPath), isNotEmpty);

    final taggedItems = await store.findMediaItemsByTagGlobal(
      category: TagCategory.artist,
      name: 'Todakenji',
    );
    expect(taggedItems.map((item) => item.id), contains(targetPath));
  });

  test('organizeAppLibrary migrates legacy 作者別 folders into 作者', () async {
    final docsDir = await Directory.systemTemp.createTemp(
      'local-tag-store-legacy-author-dir',
    );
    addTearDown(() async {
      if (await docsDir.exists()) {
        await docsDir.delete(recursive: true);
      }
    });
    PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);

    final db = AppDb();
    addTearDown(db.close);
    final store = LocalTagStore(db);

    final libraryRoot = Directory(p.join(docsDir.path, 'library'));
    final legacyArtistDir = Directory(
      p.join(libraryRoot.path, '\u4f5c\u8005\u5225', 'Legacy Artist'),
    );
    await legacyArtistDir.create(recursive: true);

    final sourcePath = p.join(legacyArtistDir.path, 'legacy.pdf');
    await File(sourcePath).writeAsBytes(const <int>[2, 4, 6]);
    final source = MediaItem(
      id: sourcePath,
      displayName: 'legacy.pdf',
      kind: MediaKind.pdf,
      folderRaw: legacyArtistDir.path,
    );

    await store.addTagToItem(
      source,
      const Tag(name: 'Legacy Artist', category: TagCategory.artist),
    );

    final moved = await store.organizeAppLibrary(libraryRoot: libraryRoot.path);
    final targetPath = p.join(
      libraryRoot.path,
      '\u4f5c\u8005',
      'Legacy Artist',
      'legacy.pdf',
    );

    expect(moved[sourcePath], targetPath);
    expect(await File(targetPath).exists(), isTrue);
    expect(
      await Directory(p.join(libraryRoot.path, '\u4f5c\u8005\u5225')).exists(),
      isFalse,
    );
  });

  test(
    'organizeAppLibrary uses series folder for items with multiple artists',
    () async {
      final docsDir = await Directory.systemTemp.createTemp(
        'local-tag-store-hitomi-collab',
      );
      addTearDown(() async {
        if (await docsDir.exists()) {
          await docsDir.delete(recursive: true);
        }
      });
      PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);

      final db = AppDb();
      addTearDown(db.close);
      final store = LocalTagStore(db);

      final libraryRoot = Directory(p.join(docsDir.path, 'library'));
      await libraryRoot.create(recursive: true);

      final sourcePath = p.join(libraryRoot.path, 'hitomi-collab.pdf');
      await File(sourcePath).writeAsBytes(const <int>[7, 7, 7]);
      final source = MediaItem(
        id: sourcePath,
        displayName: 'hitomi-collab.pdf',
        kind: MediaKind.pdf,
        folderRaw: libraryRoot.path,
      );

      await store.addTagToItem(
        source,
        const Tag(name: 'Artist A', category: TagCategory.artist),
      );
      await store.addTagToItem(
        source,
        const Tag(name: 'Artist B', category: TagCategory.artist),
      );
      await store.addTagToItem(
        source,
        const Tag(name: 'Original Series', category: TagCategory.series),
      );

      final moved = await store.organizeAppLibrary(
        libraryRoot: libraryRoot.path,
      );
      final targetPath = p.join(
        libraryRoot.path,
        '\u30b7\u30ea\u30fc\u30ba',
        'Original Series',
        'hitomi-collab.pdf',
      );

      expect(moved[sourcePath], targetPath);
      expect(await File(targetPath).exists(), isTrue);
      expect(
        await Directory(p.join(libraryRoot.path, '\u4f5c\u8005')).exists(),
        isFalse,
      );
    },
  );

  test(
    'organizeAppLibrary uses series folder when artist tags are missing',
    () async {
      final docsDir = await Directory.systemTemp.createTemp(
        'local-tag-store-series-only',
      );
      addTearDown(() async {
        if (await docsDir.exists()) {
          await docsDir.delete(recursive: true);
        }
      });
      PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);

      final db = AppDb();
      addTearDown(db.close);
      final store = LocalTagStore(db);

      final libraryRoot = Directory(p.join(docsDir.path, 'library'));
      await libraryRoot.create(recursive: true);

      final sourcePath = p.join(libraryRoot.path, 'series-only.pdf');
      await File(sourcePath).writeAsBytes(const <int>[4, 4, 4]);
      final source = MediaItem(
        id: sourcePath,
        displayName: 'series-only.pdf',
        kind: MediaKind.pdf,
        folderRaw: libraryRoot.path,
      );

      await store.addTagToItem(
        source,
        const Tag(name: 'Series Only', category: TagCategory.series),
      );

      final moved = await store.organizeAppLibrary(
        libraryRoot: libraryRoot.path,
      );
      final targetPath = p.join(
        libraryRoot.path,
        '\u30b7\u30ea\u30fc\u30ba',
        'Series Only',
        'series-only.pdf',
      );

      expect(moved[sourcePath], targetPath);
      expect(await File(targetPath).exists(), isTrue);
    },
  );

  test(
    'organizeAppLibrary uses unknown folder when multiple artists have no series',
    () async {
      final docsDir = await Directory.systemTemp.createTemp(
        'local-tag-store-collab-unknown',
      );
      addTearDown(() async {
        if (await docsDir.exists()) {
          await docsDir.delete(recursive: true);
        }
      });
      PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);

      final db = AppDb();
      addTearDown(db.close);
      final store = LocalTagStore(db);

      final libraryRoot = Directory(p.join(docsDir.path, 'library'));
      await libraryRoot.create(recursive: true);

      final sourcePath = p.join(libraryRoot.path, 'collab-no-series.pdf');
      await File(sourcePath).writeAsBytes(const <int>[5, 5, 5]);
      final source = MediaItem(
        id: sourcePath,
        displayName: 'collab-no-series.pdf',
        kind: MediaKind.pdf,
        folderRaw: libraryRoot.path,
      );

      await store.addTagToItem(
        source,
        const Tag(name: 'Artist A', category: TagCategory.artist),
      );
      await store.addTagToItem(
        source,
        const Tag(name: 'Artist B', category: TagCategory.artist),
      );

      final moved = await store.organizeAppLibrary(
        libraryRoot: libraryRoot.path,
      );
      final targetPath = p.join(
        libraryRoot.path,
        '\u4e0d\u660e',
        'collab-no-series.pdf',
      );

      expect(moved[sourcePath], targetPath);
      expect(await File(targetPath).exists(), isTrue);
    },
  );

  test(
    'organizeAppLibrary uses unknown folder when artist and series tags are missing',
    () async {
      final docsDir = await Directory.systemTemp.createTemp(
        'local-tag-store-unknown',
      );
      addTearDown(() async {
        if (await docsDir.exists()) {
          await docsDir.delete(recursive: true);
        }
      });
      PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);

      final db = AppDb();
      addTearDown(db.close);
      final store = LocalTagStore(db);

      final libraryRoot = Directory(p.join(docsDir.path, 'library'));
      await libraryRoot.create(recursive: true);

      final sourcePath = p.join(libraryRoot.path, 'unknown.pdf');
      await File(sourcePath).writeAsBytes(const <int>[6, 6, 6]);
      final source = MediaItem(
        id: sourcePath,
        displayName: 'unknown.pdf',
        kind: MediaKind.pdf,
        folderRaw: libraryRoot.path,
      );

      await store.upsertMediaItem(source);

      final moved = await store.organizeAppLibrary(
        libraryRoot: libraryRoot.path,
      );
      final targetPath = p.join(
        libraryRoot.path,
        '\u4e0d\u660e',
        'unknown.pdf',
      );

      expect(moved[sourcePath], targetPath);
      expect(await File(targetPath).exists(), isTrue);
    },
  );

  test('renameItemsUnderPathPrefix keeps tags after folder rename', () async {
    final docsDir = await Directory.systemTemp.createTemp(
      'local-tag-store-folder-rename',
    );
    addTearDown(() async {
      if (await docsDir.exists()) {
        await docsDir.delete(recursive: true);
      }
    });
    PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);

    final db = AppDb();
    addTearDown(db.close);
    final store = LocalTagStore(db);

    final libraryRoot = Directory(p.join(docsDir.path, 'library'));
    final beforeFolder = Directory(p.join(libraryRoot.path, 'before'));
    await beforeFolder.create(recursive: true);

    final beforePath = p.join(beforeFolder.path, 'sample.pdf');
    await File(beforePath).writeAsBytes(const <int>[1, 3, 5]);
    final item = MediaItem(
      id: beforePath,
      displayName: 'sample.pdf',
      kind: MediaKind.pdf,
      folderRaw: beforeFolder.path,
    );

    await store.addTagToItem(
      item,
      const Tag(name: 'Folder Artist', category: TagCategory.artist),
    );

    final afterFolderPath = p.join(libraryRoot.path, 'after');
    await beforeFolder.rename(afterFolderPath);
    await store.renameItemsUnderPathPrefix(
      beforePrefix: beforeFolder.path,
      afterPrefix: afterFolderPath,
    );

    final afterPath = p.join(afterFolderPath, 'sample.pdf');
    final tags = await store.listTagsForItem(afterPath);
    expect(tags.map((entry) => entry.tag.name), contains('Folder Artist'));
    expect(await store.listTagsForItem(beforePath), isEmpty);

    final taggedItems = await store.findMediaItemsByTagGlobal(
      category: TagCategory.artist,
      name: 'Folder Artist',
    );
    expect(taggedItems.map((entry) => entry.id), contains(afterPath));
    expect(taggedItems.map((entry) => entry.id), isNot(contains(beforePath)));
  });

  test('organizeAppLibrary suffixes duplicate target names', () async {
    final docsDir = await Directory.systemTemp.createTemp(
      'local-tag-store-conflict',
    );
    addTearDown(() async {
      if (await docsDir.exists()) {
        await docsDir.delete(recursive: true);
      }
    });
    PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);

    final db = AppDb();
    addTearDown(db.close);
    final store = LocalTagStore(db);

    final libraryRoot = Directory(p.join(docsDir.path, 'library'));
    await libraryRoot.create(recursive: true);

    final sourcePath = p.join(libraryRoot.path, 'sample.pdf');
    await File(sourcePath).writeAsBytes(const <int>[1, 2, 3]);
    final source = MediaItem(
      id: sourcePath,
      displayName: 'sample.pdf',
      kind: MediaKind.pdf,
      folderRaw: libraryRoot.path,
    );

    await store.addTagToItem(
      source,
      const Tag(name: 'Conflict Artist', category: TagCategory.artist),
    );

    final conflictDir = Directory(
      p.join(libraryRoot.path, '\u4f5c\u8005', 'Conflict Artist'),
    );
    await conflictDir.create(recursive: true);
    final conflictPath = p.join(conflictDir.path, 'sample.pdf');
    await File(conflictPath).writeAsBytes(const <int>[9, 9, 9]);

    final moved = await store.organizeAppLibrary(libraryRoot: libraryRoot.path);

    final suffixPath = p.join(conflictDir.path, 'sample (2).pdf');
    expect(moved, {sourcePath: suffixPath});
    expect(await File(sourcePath).exists(), isFalse);
    expect(await File(conflictPath).exists(), isTrue);
    expect(await File(suffixPath).exists(), isTrue);
    expect(await store.listTagsForItem(sourcePath), isEmpty);
    expect(await store.listTagsForItem(suffixPath), isNotEmpty);
  });
}

class _FakePathProviderPlatform extends PathProviderPlatform {
  final String docsPath;

  _FakePathProviderPlatform(this.docsPath);

  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;

  @override
  Future<String?> getTemporaryPath() async => docsPath;
}
