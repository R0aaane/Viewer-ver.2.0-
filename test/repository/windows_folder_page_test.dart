import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:pdf_viewer/models/folder.dart';
import 'package:pdf_viewer/models/mediaItem.dart';
import 'package:pdf_viewer/repository/folderRepository.dart';

void main() {
  test('listed image renders from its original file', () async {
    final root = await Directory.systemTemp.createTemp('viewer_page_image_');
    addTearDown(() => root.delete(recursive: true));
    final image = im.Image(width: 8, height: 12);
    await File('${root.path}/雪 #1%.PNG').writeAsBytes(im.encodePng(image));
    final repo = WindowsFolderRepository();
    final page = await repo.listMediaPage(
      FolderHandle(root.path),
      offset: 0,
      limit: 1,
    );
    final bytes = await repo.renderPageBytes(page.items.single, 1);
    final codec = await ui.instantiateImageCodec(bytes);
    addTearDown(codec.dispose);
    final frame = await codec.getNextFrame();
    addTearDown(frame.image.dispose);
    expect(frame.image.width, 8);
    expect(frame.image.height, 12);
  });

  test(
    'pages reflect external changes and GIF collection membership',
    () async {
      final root = await Directory.systemTemp.createTemp('viewer_page_');
      addTearDown(() => root.delete(recursive: true));
      final repo = WindowsFolderRepository();
      final folder = FolderHandle(root.path);
      final child = await Directory('${root.path}/z').create();
      final original = await File('${root.path}/雪 #1%.PNG').create();
      await File('${root.path}/ignored.txt').create();
      final first = await repo.listMediaPage(folder, offset: 0, limit: 1);
      expect(first.total, 2);
      expect(first.items.single.kind, MediaKind.folder);
      final next = await repo.listMediaPage(folder, offset: 1, limit: 1);
      expect(next.items.single.displayName, '雪 #1%.PNG');
      final member = File('${child.path}/p.GIF');
      await member.writeAsBytes([2]);
      final firstMember = File('${child.path}/A.gif');
      await firstMember.writeAsBytes([1]);
      await original.rename('${root.path}/a.pdf');
      final progress = <int>[];
      final updated = await repo.listMediaPage(
        folder,
        offset: 0,
        limit: 3,
        onProgress: (n, total) {
          expect(total, 2);
          progress.add(n);
        },
      );
      expect(updated.items.map((item) => item.displayName), ['a.pdf', 'z']);
      expect(updated.items.last.mimeType, 'application/x.gif-collection');
      expect(progress, [1, 2]);
      expect(await repo.getPageCount(updated.items.last), 2);
      expect(await repo.renderPageBytes(updated.items.last, 1), [1]);
      expect(await repo.renderPageBytes(updated.items.last, 2), [2]);
      await member.delete();
      await firstMember.delete();
      expect(
        (await repo.listMediaPage(
          folder,
          offset: 0,
          limit: 1,
        )).items.single.kind,
        MediaKind.folder,
      );
    },
  );

  test(
    'measure Windows listing with 30000 generated media files',
    () async {
      final root = await Directory.systemTemp.createTemp('viewer_scan_bench_');
      addTearDown(() => root.delete(recursive: true));
      final collection = await Directory('${root.path}/collection').create();
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jVZkAAAAASUVORK5CYII=',
      );
      final gif = base64Decode(
        'R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==',
      );
      for (var i = 0; i < 30000; i++) {
        final name = 'Image_${i.toString().padLeft(5, '0')}';
        if (i < 3000) {
          File('${collection.path}/$name.gif').writeAsBytesSync(gif);
        } else {
          File('${root.path}/$name.png').writeAsBytesSync(png);
        }
      }
      final repo = WindowsFolderRepository();
      for (final offset in [0, 20, 40, 60, 80, 100]) {
        final timer = Stopwatch()..start();
        final result = await repo.listMediaPage(
          FolderHandle(root.path),
          offset: offset,
          limit: 20,
        );
        timer.stop();
        expect(result.total, 27001);
        expect(result.items.length, 20);
        // ignore: avoid_print
        print('page offset=$offset elapsed_ms=${timer.elapsedMilliseconds}');
      }
    },
    skip: !const bool.fromEnvironment('MEASURE_FOLDER_PAGE'),
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
