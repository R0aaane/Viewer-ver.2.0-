import 'dart:typed_data';
import '../support/ui_review_capture.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdf_viewer/app/app_theme.dart';
import 'package:pdf_viewer/database/tag_service.dart';
import 'package:pdf_viewer/models/folder.dart';
import 'package:pdf_viewer/models/mediaItem.dart';
import 'package:pdf_viewer/models/metadata_settings.dart';
import 'package:pdf_viewer/models/tag.dart';
import 'package:pdf_viewer/models/tag_with_id.dart';
import 'package:pdf_viewer/repository/mediaRepository.dart';
import 'package:pdf_viewer/scene/detailImage.dart';
import 'package:pdf_viewer/scene/gridGallery.dart';
import 'package:pdf_viewer/services/host_api_server_service.dart';
import 'package:pdf_viewer/scene/widgets/inspector_pane.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Repository extends Fake implements MediaRepository {
  int renders = 0;
  @override
  bool get isRemoteMode => false;
  @override
  RepositoryCapabilities get capabilities => const RepositoryCapabilities(
    canRename: false,
    canDelete: false,
    canUpload: false,
    canRecursiveSearch: true,
    canExportPdf: false,
    canOrganizeLibrary: false,
    canPickFolder: false,
    canAddLocalFolder: false,
    canImportToHost: false,
    canBatchUpload: false,
    canAssignImportTags: false,
  );
  @override
  Future<Uint8List> renderPageBytes(
    MediaItem item,
    int page, {
    int maxWidth = 1600,
  }) async {
    renders++;
    return bytes;
  }

  final Uint8List bytes = _testImage();

  @override
  Future<FolderHandle> getAppLibraryFolder() async => FolderHandle('test');
  @override
  Future<List<MediaItem>> listMediaRecursiveFiles(
    FolderHandle folder, {
    void Function(int, int)? onProgress,
  }) async => [];
}

class _LibraryRepository extends _Repository {
  @override
  bool get isRemoteMode => true;
  @override
  bool get canImportFromUrl => false;
  @override
  AppMode get appMode => AppMode.standalone;
  final items = List.generate(
    6,
    (index) => MediaItem(
      id: 'image-$index',
      displayName: 'Landscape $index.png',
      kind: MediaKind.image,
      folderRaw: 'test',
    ),
  );
  @override
  Future<List<FolderHandle>> listAvailableFolders() async => [
    FolderHandle('test'),
  ];
  @override
  Future<List<MediaItem>> listMedia(
    FolderHandle folder, {
    void Function(int, int)? onProgress,
  }) async => items;
  @override
  Future<List<MediaItem>> listMediaRecursiveFiles(
    FolderHandle folder, {
    void Function(int, int)? onProgress,
  }) async => items;
  @override
  Future<PagedMediaResult> listMediaPage(
    FolderHandle folder, {
    required int offset,
    required int limit,
    void Function(int, int)? onProgress,
  }) async => PagedMediaResult(items: items, total: items.length);
  @override
  Future<ThumbPair> readThumbPair(MediaItem item, {int maxWidth = 360}) async =>
      ThumbPair(front: bytes);
}

class _Host extends Fake implements HostApiServerService {
  @override
  Future<void> refresh() async {}
}

Uint8List _testImage() {
  final canvas = img.Image(width: 120, height: 160);
  for (var y = 0; y < 160; y++) {
    for (var x = 0; x < 120; x++) {
      canvas.setPixelRgb(x, y, 48 + x ~/ 3, 70 + y ~/ 3, 100);
    }
  }
  return img.encodePng(canvas);
}

class _Tags extends Fake implements TagService {
  @override
  Future<List<MediaItem>?> listRemoteFavoriteItems() async => null;
  @override
  Future<List<MediaItem>?> listRemoteRatedMediaItems(int rating) async => null;
  @override
  void rememberItems(Iterable<MediaItem> items) {}
  @override
  Future<Map<String, List<TagWithId>>> getDetailedTagsByItems(
    List<MediaItem> items,
  ) async => {for (final item in items) item.id: []};
  @override
  MetadataSettings get settings => const MetadataSettings();
  @override
  bool get isRemoteMode => false;
  @override
  Future<Set<String>?> listRemoteFavoriteIds() async => null;
  @override
  Future<Map<String, int>?> listRemoteRatings() async => null;
  @override
  Future<Set<String>> favoriteLookupIdsForItem(MediaItem item) async => {
    item.id,
  };
  @override
  Future<List<TagWithId>> listTagsForItem(
    String itemId, {
    MediaItem? item,
  }) async => [];
  @override
  Future<List<TagWithId>> listTagMasterByCategory(
    TagCategory category, {
    String? contains,
    int limit = 200,
  }) async => [];
}

void main() {
  for (final width in [360.0, 1280.0]) {
    testWidgets('home and library inspector at $width', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await loadUiReviewFonts(tester);
      final key = GlobalKey();
      final repo = _LibraryRepository();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(
            fontFamily: captureUiReview ? 'ReviewFont' : null,
          ),
          builder: (_, child) => RepaintBoundary(key: key, child: child!),
          home: GalleryGridPage(
            repo: repo,
            tagService: _Tags(),
            hostServerService: _Host(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('あなたのライブラリ'), findsOneWidget);
      expect(find.text('最近追加'), findsWidgets);
      await tester.runAsync(
        () => precacheImage(
          MemoryImage(repo.bytes),
          tester.element(find.byType(GalleryGridPage)),
        ),
      );
      await tester.pumpAndSettle();
      await saveUiReview(tester, key, 'home_${width.toInt()}');
      await tester.tap(find.byTooltip('詳細を見る').first);
      await tester.pumpAndSettle();
      expect(find.byType(InspectorPane), findsOneWidget);
      await tester.tap(find.byTooltip('詳細を閉じる'));
      await tester.pumpAndSettle();
      if (width >= 980) {
        await tester.tap(find.text('ギャラリー'));
      } else {
        await tester.tap(find.byType(NavigationDestination).at(1));
      }
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('アイテムメニュー').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('詳細を見る'));
      await tester.pumpAndSettle();
      expect(find.byType(InspectorPane), findsOneWidget);
      expect(tester.takeException(), isNull);
      await saveUiReview(tester, key, 'library_inspector_${width.toInt()}');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  }
  for (final scale in [1.0, 2.0]) {
    for (final width in [360.0, 1280.0]) {
      testWidgets(
        'reader settings and details remain accessible at $width scale $scale',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await loadUiReviewFonts(tester);
          final reviewKey = GlobalKey();
          final repo = _Repository();
          await tester.pumpWidget(
            MaterialApp(
              theme: buildAppTheme(
                fontFamily: captureUiReview ? 'ReviewFont' : null,
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: RepaintBoundary(key: reviewKey, child: child!),
              ),
              home: ImageDetailPage(
                repo: repo,
                tagService: _Tags(),
                initialIndex: 0,
                items: const [
                  MediaItem(
                    id: 'image',
                    displayName: 'Landscape.png',
                    kind: MediaKind.image,
                    folderRaw: 'test',
                  ),
                ],
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.runAsync(
            () => precacheImage(
              MemoryImage(repo.bytes),
              tester.element(find.byType(ImageDetailPage)),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester.widget<RawImage>(find.byType(RawImage).first).image,
            isNotNull,
          );
          final rendered = repo.renders;
          await tester.tap(find.byTooltip('詳細・タグ'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await saveUiReview(
            tester,
            reviewKey,
            'reader_${width.toInt()}_${scale.toInt()}x',
          );
          if (width >= 980) {
            expect(find.byType(InspectorPane), findsOneWidget);
            expect(
              repo.renders,
              rendered,
              reason: 'Opening metadata must reuse the reader image',
            );
            await tester.tap(find.byTooltip('詳細を閉じる'));
          } else {
            expect(find.text('付与済みタグ'), findsOneWidget);
            await tester.tap(find.text('閲覧'));
          }
          await tester.pumpAndSettle();
          if (width >= 980) {
            await tester.tap(find.byTooltip('フルスクリーン'));
          } else {
            await tester.tap(find.byTooltip('その他の操作'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('フルスクリーン'));
          }
          await tester.pumpAndSettle();
          expect(find.byType(AppBar), findsNothing);
          await tester.tap(find.byTooltip('フルスクリーン解除'));
          await tester.pumpAndSettle();
          expect(find.byType(AppBar), findsOneWidget);
          await tester.tap(find.byTooltip('閲覧設定・フォルダ'));
          await tester.pumpAndSettle();
          expect(find.text('見開き表示 (ON/OFF)'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
        },
      );
    }
  }
}
