import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pdf_viewer/database/app_db.dart';
import 'package:pdf_viewer/database/tag_service.dart';
import 'package:pdf_viewer/models/mediaItem.dart';
import 'package:pdf_viewer/models/tag.dart';
import 'package:pdf_viewer/models/tag_with_id.dart';
import 'package:pdf_viewer/models/metadata_settings.dart';
import 'package:pdf_viewer/services/media_id_resolver.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PathProviderPlatform originalPathProvider;

  setUp(() {
    originalPathProvider = PathProviderPlatform.instance;
  });

  tearDown(() {
    PathProviderPlatform.instance = originalPathProvider;
  });

  group('TagService host mirror sync', () {
    test('hydrates remote tags into the host local database', () async {
      final harness = await _HostMirrorTestHarness.create();
      addTearDown(harness.dispose);

      await harness.seedRemoteTags(const <Tag>[
        Tag(name: 'todakenji', category: TagCategory.artist),
        Tag(name: 'Muzenjo', category: TagCategory.series),
      ]);

      final tags = await harness.tagService.listTagsForItem(
        harness.item.id,
        item: harness.item,
      );

      expect(_tagNames(tags), <String>{
        'artist:todakenji',
        'series:Muzenjo',
      });
      expect(
        _tagNamesFromPlain(await harness.tagService.listLocallyStoredTagsForItem(harness.item)),
        <String>{
          'artist:todakenji',
          'series:Muzenjo',
        },
      );
    });

    test('keeps existing remote tags when a host user adds a new tag', () async {
      final harness = await _HostMirrorTestHarness.create();
      addTearDown(harness.dispose);

      await harness.seedRemoteTags(const <Tag>[
        Tag(name: 'todakenji', category: TagCategory.artist),
        Tag(name: 'Muzenjo', category: TagCategory.series),
      ]);

      await harness.tagService.addTagToItem(
        harness.item,
        const Tag(name: 'test', category: TagCategory.artist),
      );

      expect(await harness.remoteTagNames(), <String>{
        'artist:test',
        'artist:todakenji',
        'series:Muzenjo',
      });
      expect(
        _tagNamesFromPlain(await harness.tagService.listLocallyStoredTagsForItem(harness.item)),
        <String>{
          'artist:test',
          'artist:todakenji',
          'series:Muzenjo',
        },
      );
    });

    test('removes only the selected tag while preserving other remote tags', () async {
      final harness = await _HostMirrorTestHarness.create();
      addTearDown(harness.dispose);

      await harness.seedRemoteTags(const <Tag>[
        Tag(name: 'todakenji', category: TagCategory.artist),
        Tag(name: 'Muzenjo', category: TagCategory.series),
      ]);
      await harness.tagService.addTagToItem(
        harness.item,
        const Tag(name: 'test', category: TagCategory.artist),
      );

      final currentTags = await harness.tagService.listTagsForItem(
        harness.item.id,
        item: harness.item,
      );
      final testTag = currentTags.firstWhere(
        (entry) =>
            entry.tag.category == TagCategory.artist &&
            entry.tag.name == 'test',
      );

      await harness.tagService.removeTagFromItem(
        harness.item.id,
        testTag.tagId,
        item: harness.item,
      );

      expect(await harness.remoteTagNames(), <String>{
        'artist:todakenji',
        'series:Muzenjo',
      });
      expect(
        _tagNamesFromPlain(await harness.tagService.listLocallyStoredTagsForItem(harness.item)),
        <String>{
          'artist:todakenji',
          'series:Muzenjo',
        },
      );
    });
  });
}

Set<String> _tagNames(Iterable<TagWithId> tags) {
  return tags
      .map((entry) => '${entry.tag.category.name}:${entry.tag.name}')
      .toSet();
}

Set<String> _tagNamesFromPlain(Iterable<Tag> tags) {
  return tags.map((tag) => '${tag.category.name}:${tag.name}').toSet();
}

class _HostMirrorTestHarness {
  final Directory docsDir;
  final HttpServer server;
  final AppDb db;
  final TagService tagService;
  final MediaItem item;
  final String stableId;
  final Map<String, List<Map<String, String>>> tagsByMediaId;

  const _HostMirrorTestHarness({
    required this.docsDir,
    required this.server,
    required this.db,
    required this.tagService,
    required this.item,
    required this.stableId,
    required this.tagsByMediaId,
  });

  static Future<_HostMirrorTestHarness> create() async {
    final docsDir = await Directory.systemTemp.createTemp('tag-service-host');
    PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);

    final item = MediaItem(
      id: r'C:\library\sample.pdf',
      displayName: 'sample.pdf',
      kind: MediaKind.pdf,
      folderRaw: r'C:\library',
      modified: DateTime.utc(2026, 4, 1),
      sizeBytes: 1234,
      tags: const <Tag>[],
    );
    final stableId = (await MediaIdResolver().resolve(item)).stableId;
    final tagsByMediaId = <String, List<Map<String, String>>>{};

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(_serveHostMirror(server, tagsByMediaId));

    SharedPreferences.setMockInitialValues(<String, Object>{
      'prefs.app.mode': AppMode.host.index,
      'prefs.host.port': server.port,
    });

    final db = AppDb();
    final tagService = TagService(db);
    await tagService.initialize();
    tagService.rememberItem(item);

    return _HostMirrorTestHarness(
      docsDir: docsDir,
      server: server,
      db: db,
      tagService: tagService,
      item: item,
      stableId: stableId,
      tagsByMediaId: tagsByMediaId,
    );
  }

  Future<void> seedRemoteTags(List<Tag> tags) async {
    tagsByMediaId[stableId] = tags
        .map(
          (tag) => <String, String>{
            'name': tag.name,
            'category': tag.category.name,
          },
        )
        .toList(growable: false);
  }

  Future<Set<String>> remoteTagNames() async {
    final rows = tagsByMediaId[stableId] ?? const <Map<String, String>>[];
    return rows
        .map((row) => '${row['category']}:${row['name']}')
        .toSet();
  }

  Future<void> dispose() async {
    await db.close();
    await server.close(force: true);
    if (await docsDir.exists()) {
      await docsDir.delete(recursive: true);
    }
  }
}

Future<void> _serveHostMirror(
  HttpServer server,
  Map<String, List<Map<String, String>>> tagsByMediaId,
) async {
  await for (final request in server) {
    final mediaId = request.uri.pathSegments.isNotEmpty
        ? Uri.decodeComponent(request.uri.pathSegments.last)
        : '';

    if (request.method == 'GET' &&
        request.uri.pathSegments.length >= 3 &&
        request.uri.pathSegments[0] == 'tags' &&
        request.uri.pathSegments[1] == 'item') {
      final items = tagsByMediaId[mediaId] ?? const <Map<String, String>>[];
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(<String, Object?>{
          'mediaId': mediaId,
          'items': items
              .asMap()
              .entries
              .map(
                (entry) => <String, String>{
                  'tagId': '${entry.value['category']}:${entry.key}',
                  'name': entry.value['name'] ?? '',
                  'category': entry.value['category'] ?? '',
                },
              )
              .toList(growable: false),
        }),
      );
      await request.response.close();
      continue;
    }

    if (request.method == 'PUT' &&
        request.uri.pathSegments.length >= 3 &&
        request.uri.pathSegments[0] == 'tags' &&
        request.uri.pathSegments[1] == 'item') {
      final body = await utf8.decoder.bind(request).join();
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final tags = (decoded['tags'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<Map>()
          .map(
            (entry) => <String, String>{
              'name': entry['name']?.toString() ?? '',
              'category': entry['category']?.toString() ?? '',
            },
          )
          .where(
            (entry) => entry['name']!.trim().isNotEmpty &&
                entry['category']!.trim().isNotEmpty,
          )
          .toList(growable: false);
      tagsByMediaId[mediaId] = tags;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(<String, Object?>{
          'ok': true,
          'mediaId': mediaId,
        }),
      );
      await request.response.close();
      continue;
    }

    if (request.method == 'POST' && request.uri.path == '/rescan') {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(<String, Object?>{
          'ok': true,
          'message': 'rescanned',
        }),
      );
      await request.response.close();
      continue;
    }

    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }
}

class _FakePathProviderPlatform extends PathProviderPlatform {
  final String docsPath;

  _FakePathProviderPlatform(this.docsPath);

  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;

  @override
  Future<String?> getTemporaryPath() async => docsPath;
}
