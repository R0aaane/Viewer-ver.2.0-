import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pdf_viewer/database/app_db.dart';
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

  test('renameItem keeps tags when destination media record already exists', () async {
    final docsDir = await Directory.systemTemp.createTemp('local-tag-store-rename');
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
      tags.map((entry) => '${entry.tag.category.name}:${entry.tag.name}').toSet(),
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
  });

  test('organizeAppLibrary keeps moved items searchable by tag', () async {
    final docsDir = await Directory.systemTemp.createTemp('local-tag-store-organize');
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

    expect(targetPath, isNotNull);
    expect(await File(targetPath!).exists(), isTrue);
    expect(await store.listTagsForItem(targetPath), isNotEmpty);

    final taggedItems = await store.findMediaItemsByTagGlobal(
      category: TagCategory.artist,
      name: 'Todakenji',
    );
    expect(taggedItems.map((item) => item.id), contains(targetPath));
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
