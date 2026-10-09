import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pdf_viewer/database/app_db.dart';
import 'package:pdf_viewer/models/mediaItem.dart';
import 'package:pdf_viewer/repository/android_folder_repository.dart';
import 'package:pdf_viewer/repository/folderRepository.dart';
import 'package:pdf_viewer/repository/mediaRepository.dart';
import 'package:pdf_viewer/repository/remote_media_repository.dart';
import 'package:pdf_viewer/services/media_id_resolver.dart';
import 'package:pdf_viewer/services/remote_media_api_client.dart';
import 'package:pdfx/src/renderer/interfaces/platform.dart';

import '../support/fake_pdf.dart';

class _UnusedDb extends Fake implements AppDb {}

class _UnusedLocalRepository extends Fake implements MediaRepository {}

class _RemoteIdentity extends MediaIdResolver {
  @override
  Future<ResolvedMediaIdentity> resolve(MediaItem item) async =>
      ResolvedMediaIdentity(
        stableId: item.id,
        aliases: [item.id],
        sizeBytes: null,
        modifiedEpochMs: null,
        normalizedPath: item.id,
        relativePathHint: item.displayName,
      );
}

class _RemotePdfApi extends RemoteMediaApiClient {
  _RemotePdfApi() : super(baseUrl: 'http://localhost');
  int downloads = 0;

  @override
  Future<RemoteMediaMeta> fetchMediaMeta(
    String mediaId, {
    ResolvedMediaIdentity? identity,
  }) async => RemoteMediaMeta(
    mediaId: mediaId,
    displayName: '$mediaId.pdf',
    kind: 'pdf',
    mimeType: 'application/pdf',
    sizeBytes: 8,
    modifiedAt: null,
    etag: 'test',
    supportsRange: true,
    pageCount: 10,
  );

  @override
  Future<void> downloadMediaToFile(String mediaId, File destination) async {
    downloads++;
    await destination.writeAsBytes('%PDF-1.7'.codeUnits);
  }
}

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late PdfxPlatform originalPdf;
  late PathProviderPlatform originalPaths;
  late FakePdfPlatform pdf;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('pdf-resource-test-');
    originalPdf = PdfxPlatform.instance;
    originalPaths = PathProviderPlatform.instance;
    PdfxPlatform.instance = pdf = FakePdfPlatform();
    PathProviderPlatform.instance = _TestPaths(temp.path);
  });

  tearDown(() async {
    PdfxPlatform.instance = originalPdf;
    PathProviderPlatform.instance = originalPaths;
    await temp.delete(recursive: true);
  });

  Future<MediaItem> item(String name) async {
    final file = File('${temp.path}/$name.pdf');
    await file.writeAsBytes([1]);
    return MediaItem(
      id: file.path,
      displayName: '$name.pdf',
      kind: MediaKind.pdf,
      folderRaw: temp.path,
    );
  }

  for (final android in [false, true]) {
    final platform = android ? 'Android' : 'Windows';
    (MediaRepository, Future<void> Function()) newRepository() {
      if (android) {
        final repo = AndroidFolderRepository(_UnusedDb());
        return (repo, repo.dispose);
      }
      final repo = WindowsFolderRepository();
      return (repo, repo.dispose);
    }

    test('$platform thumbnail completes and releases page/document', () async {
      final (repository, dispose) = newRepository();
      addTearDown(dispose);
      final result = await repository
          .readThumbPair(await item('thumbnail'))
          .timeout(const Duration(seconds: 3));
      expect(result.front, [1, 2, 3]);
      expect(pdf.documents.single.closedPages, 1);
      expect(pdf.documents.single.closeCount, 1);
    });

    test('$platform failed render closes the page and permits retry', () async {
      final (repository, dispose) = newRepository();
      addTearDown(dispose);
      final media = await item('failure');
      pdf.failRender = true;
      await expectLater(repository.renderPageBytes(media, 1), throwsStateError);
      final document = pdf.documents.single;
      expect(document.closedPages, 1);
      document.failRender = false;
      expect(await repository.renderPageBytes(media, 2), [1, 2, 3]);
      expect(document.closedPages, 2);
    });

    test('$platform LRU and disposal wait for an active page', () async {
      final (repo, dispose) = newRepository();
      final media = await item('active');
      await repo.getPageCount(media);
      final document = pdf.documents.single;
      final release = Completer<void>();
      document.renderGate = release;
      final rendering = repo.renderPageBytes(media, 1);
      // The pending operation is pinned even before getPage completes.
      for (var index = 0; index < 8; index++) {
        await repo.getPageCount(await item('other-$index'));
      }
      expect(document.closed, isFalse);
      final disposal = dispose();
      expect(document.closed, isFalse);
      release.complete();
      await rendering;
      await disposal;
      expect(pdf.documents.every((doc) => doc.closeCount == 1), isTrue);
    });
  }

  MediaItem remoteItem(String name) => MediaItem(
    id: 'mid_$name',
    displayName: '$name.pdf',
    kind: MediaKind.pdf,
    folderRaw: 'remote://library',
  );

  RemoteMediaRepository remoteRepository(_RemotePdfApi api) =>
      RemoteMediaRepository(
        apiClient: api,
        idResolver: _RemoteIdentity(),
        localPickerRepository: _UnusedLocalRepository(),
      );

  test(
    'Remote failed render closes its page without downloading again',
    () async {
      final api = _RemotePdfApi();
      final repo = remoteRepository(api);
      addTearDown(repo.dispose);
      final media = remoteItem('failure');
      await repo.getPageCount(media);
      final document = pdf.documents.last;
      document.failRender = true;
      await expectLater(repo.renderPageBytes(media, 1), throwsStateError);
      expect(document.closedPages, 1);
      document.failRender = false;
      expect(await repo.renderPageBytes(media, 2), [1, 2, 3]);
      expect(document.closedPages, 2);
      expect(api.downloads, 1);
    },
  );

  test('Remote LRU and disposal wait for an active page', () async {
    final repo = remoteRepository(_RemotePdfApi());
    final media = remoteItem('active');
    await repo.getPageCount(media);
    final document = pdf.documents.last;
    final release = Completer<void>();
    document.renderGate = release;
    final rendering = repo.renderPageBytes(media, 1);
    for (var index = 0; index < 8; index++) {
      await repo.getPageCount(remoteItem('other-$index'));
    }
    expect(document.closed, isFalse);
    final disposal = repo.dispose();
    expect(document.closed, isFalse);
    release.complete();
    await rendering;
    await disposal;
    expect(pdf.documents.every((doc) => doc.closeCount == 1), isTrue);
  });
}
