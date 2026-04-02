import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pdf_viewer/services/local_path_operation_service.dart';

void main() {
  test('renameItem rejects duplicate target names', () async {
    final tempDir = await Directory.systemTemp.createTemp('local-path-rename');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final source = File(p.join(tempDir.path, 'source.pdf'));
    final target = File(p.join(tempDir.path, 'target.pdf'));
    await source.writeAsBytes(const <int>[1, 2, 3]);
    await target.writeAsBytes(const <int>[9, 9, 9]);

    await expectLater(
      () => LocalPathOperationService.renameItem(
        sourcePath: source.path,
        targetPath: target.path,
        isDirectory: false,
      ),
      throwsA(isA<LocalPathOperationException>()),
    );

    expect(await source.exists(), isTrue);
    expect(await target.exists(), isTrue);
  });

  test('copyItem treats the same file as a no-op', () async {
    final tempDir = await Directory.systemTemp.createTemp('local-path-copy');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final source = File(p.join(tempDir.path, 'same.pdf'));
    await source.writeAsBytes(const <int>[4, 5, 6]);

    final copied = await LocalPathOperationService.copyItem(
      sourcePath: source.path,
      targetPath: source.path,
      overwrite: false,
    );

    expect(copied, isFalse);
    expect(await source.exists(), isTrue);
  });
}
