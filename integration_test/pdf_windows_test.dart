import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf_viewer/database/tag_service.dart';
import 'package:pdf_viewer/models/mediaItem.dart';
import 'package:pdf_viewer/models/metadata_settings.dart';
import 'package:pdf_viewer/repository/folderRepository.dart';
import 'package:pdf_viewer/scene/detailImage.dart';
import 'package:pdf_viewer/services/app_settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Only generated fixtures under this test's temporary directory are modified.
class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;
  @override
  Future<String?> getTemporaryPath() async => path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _NoTags extends Fake implements TagService {
  @override
  Future<Set<String>?> listRemoteFavoriteIds() async => null;
  @override
  Future<Map<String, int>?> listRemoteRatings() async => null;
  @override
  Future<Set<String>> favoriteLookupIdsForItem(MediaItem item) async => {
    item.id,
  };
  @override
  Future<List<TagWithId>> listTagsForItem(String id, {MediaItem? item}) async =>
      [];
}

Future<MediaItem> _pdf(
  Directory dir,
  String name,
  int pages, {
  bool large = false,
}) async {
  final document = pw.Document();
  var random = 0x12345678;
  for (var page = 0; page < pages; page++) {
    pw.Widget content = pw.Center(child: pw.Text('Page ${page + 1}'));
    if (large) {
      final rgb = Uint8List(1024 * 1024 * 3);
      for (var i = 0; i < rgb.length; i++) {
        random = (1664525 * random + 1013904223) & 0xffffffff;
        rgb[i] = random >> 24;
      }
      final source = im.Image.fromBytes(
        width: 1024,
        height: 1024,
        bytes: rgb.buffer,
        numChannels: 3,
      );
      content = pw.Image(pw.MemoryImage(im.encodePng(source)));
    }
    document.addPage(
      pw.Page(pageFormat: PdfPageFormat.a4, build: (_) => content),
    );
  }
  final file = File('${dir.path}/$name.pdf');
  await file.writeAsBytes(await document.save());
  return MediaItem(
    id: file.path,
    displayName: '$name.pdf',
    kind: MediaKind.pdf,
    folderRaw: dir.path,
    sizeBytes: await file.length(),
  );
}

Future<void> _until(WidgetTester tester, bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for reader UI');
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(tester.takeException(), isNull);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late PathProviderPlatform originalPaths;
  late WindowsFolderRepository repo;

  setUp(() async {
    expect(Platform.isWindows, isTrue, reason: 'Run with -d windows');
    temp = await Directory.systemTemp.createTemp('pdf-viewer-native-test-');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(temp.path);
    SharedPreferences.setMockInitialValues({'prefs.sidebarCollapsed': true});
    repo = WindowsFolderRepository();
  });
  tearDown(() async {
    await repo.dispose();
    PathProviderPlatform.instance = originalPaths;
    await temp.delete(recursive: true);
  });

  testWidgets('native 1000-page PDF, rapid switching, and resource release', (
    tester,
  ) async {
    final many = await _pdf(temp, 'many-pages', 1000);
    expect(await repo.getPageCount(many), 1000);
    for (final page in [1, 500, 1000]) {
      final png = await repo.renderPageBytes(many, page, maxWidth: 480);
      expect(im.decodePng(png)?.width, 480);
    }
    final items = <MediaItem>[];
    for (var i = 0; i < 12; i++) {
      items.add(await _pdf(temp, 'switch-$i', 3));
    }
    final sw = Stopwatch()..start();
    final rendered = await Future.wait([
      for (var round = 0; round < 3; round++)
        for (final item in items)
          repo.renderPageBytes(item, round + 1, maxWidth: 320),
    ]);
    expect(rendered, hasLength(36));
    expect(
      rendered.every((bytes) => im.decodePng(bytes)?.width == 320),
      isTrue,
    );
    await repo.dispose();
    // Windows file operations verify that native handles are no longer held.
    for (final item in items) {
      final moved = await File(item.id).rename('${item.id}.released');
      await moved.delete();
    }
    debugPrint(
      'NATIVE_METRIC switching_ms=${sw.elapsedMilliseconds} rss=${ProcessInfo.currentRss}',
    );
  });

  testWidgets(
    'native image-heavy PDF over 32 MiB renders first and last pages',
    (tester) async {
      final large = await _pdf(temp, 'image-heavy', 12, large: true);
      expect(large.sizeBytes, greaterThan(32 * 1024 * 1024));
      final sw = Stopwatch()..start();
      final before = ProcessInfo.currentRss;
      expect(await repo.getPageCount(large), 12);
      for (final page in [1, 12]) {
        expect(
          im
              .decodePng(await repo.renderPageBytes(large, page, maxWidth: 800))
              ?.width,
          800,
        );
      }
      debugPrint(
        'NATIVE_METRIC large_bytes=${large.sizeBytes} render_ms=${sw.elapsedMilliseconds} rss_before=$before rss_after=${ProcessInfo.currentRss}',
      );
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  testWidgets('native page editing, rename, and corrupt PDF recovery', (
    tester,
  ) async {
    final item = await _pdf(temp, 'editable', 3);
    final before = await repo.renderPageBytes(item, 2, maxWidth: 320);
    final updated = await repo.deletePdfPage(item, 1);
    expect(await repo.getPageCount(updated), 2);
    expect(await repo.renderPageBytes(updated, 1, maxWidth: 320), before);
    final renamed = await repo.rename(updated, 'renamed');
    expect(await repo.getPageCount(renamed), 2);
    final badFile = File('${temp.path}/broken.pdf');
    await badFile.writeAsBytes('%PDF-broken'.codeUnits);
    final bad = MediaItem(
      id: badFile.path,
      displayName: 'broken.pdf',
      kind: MediaKind.pdf,
      folderRaw: temp.path,
    );
    await expectLater(repo.getPageCount(bad), throwsA(anything));
    expect(im.decodePng(await repo.renderPageBytes(renamed, 2))?.width, 1600);
  });

  testWidgets('native rename invalidates the old path before path reuse', (
    tester,
  ) async {
    final original = await _pdf(temp, 'reused', 3);
    expect(await repo.getPageCount(original), 3);
    final rendering = Future.wait([
      for (var page = 1; page <= 3; page++)
        repo.renderPageBytes(original, page, maxWidth: 320),
    ]);
    final moved = await repo.rename(original, 'moved');
    expect(await rendering, hasLength(3));
    final replacement = await _pdf(temp, 'reused', 5);
    expect(await repo.getPageCount(replacement), 5);
    expect(await repo.getPageCount(moved), 3);
  });

  testWidgets('native deletion waits for accepted page renders', (
    tester,
  ) async {
    final item = await _pdf(temp, 'deleted', 3);
    await repo.getPageCount(item);
    final rendering = Future.wait([
      for (var page = 1; page <= 3; page++)
        repo.renderPageBytes(item, page, maxWidth: 320),
    ]);
    expect(await repo.deleteItem(item), isTrue);
    expect(await rendering, hasLength(3));
    expect(await File(item.id).exists(), isFalse);
    await expectLater(repo.getPageCount(item), throwsA(anything));
  });

  testWidgets('reader page navigation, zoom/pan, bookmark and resume', (
    tester,
  ) async {
    final item = await _pdf(temp, 'reader', 6);
    // A loopback test server exercises the real progress HTTP client without
    // touching the user's host, database or preferences.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    Map<String, dynamic>? progress;
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      if (request.method == 'PUT') {
        final update =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        progress = {
          ...?progress,
          ...update,
          'mediaId': request.uri.pathSegments.last,
        };
      }
      if (progress == null) {
        request.response.statusCode = 404;
        request.response.write('{}');
      } else {
        request.response.write(jsonEncode(progress));
      }
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));
    await AppSettingsService().saveMetadataSettings(
      MetadataSettings(
        appMode: AppMode.client,
        clientApiBaseUrl: 'http://127.0.0.1:${server.port}',
      ),
    );
    Widget reader(String key) => MaterialApp(
      home: ImageDetailPage(
        key: ValueKey(key),
        repo: repo,
        tagService: _NoTags(),
        items: [item],
        initialIndex: 0,
      ),
    );
    await tester.pumpWidget(reader('first'));
    await _until(
      tester,
      () =>
          find.text('1/6').evaluate().isNotEmpty &&
          find.byType(InteractiveViewer).evaluate().isNotEmpty,
    );
    await tester.tap(find.byTooltip('次').first);
    await _until(tester, () => find.text('2/6').evaluate().isNotEmpty);
    await tester.tap(find.byTooltip('しおりを挟む'));
    await _until(tester, () => find.byTooltip('しおりを外す').evaluate().isNotEmpty);
    final viewer = find.byType(InteractiveViewer).first;
    final transform = find
        .descendant(of: viewer, matching: find.byType(Transform))
        .first;
    final initial = tester.widget<Transform>(transform).transform.clone();
    final center = tester.getCenter(viewer);
    final first = await tester.createGesture(pointer: 1);
    final second = await tester.createGesture(pointer: 2);
    await first.down(center - const Offset(40, 0));
    await second.down(center + const Offset(40, 0));
    await tester.pump();
    await first.moveTo(center - const Offset(120, 0));
    await second.moveTo(center + const Offset(120, 0));
    await tester.pump();
    await first.up();
    await second.up();
    await tester.pump();
    final zoomed = tester.widget<Transform>(transform).transform.clone();
    expect(
      zoomed.getMaxScaleOnAxis(),
      greaterThan(initial.getMaxScaleOnAxis()),
    );
    await tester.drag(viewer, const Offset(0, 80));
    await tester.pump();
    expect(tester.widget<Transform>(transform).transform, isNot(zoomed));
    await _until(
      tester,
      () => progress?['currentPage'] == 2 && progress?['isBookmarked'] == true,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpWidget(reader('resumed'));
    await _until(
      tester,
      () =>
          find.text('2/6').evaluate().isNotEmpty &&
          find.byTooltip('しおりを外す').evaluate().isNotEmpty,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 500));
  });
}
