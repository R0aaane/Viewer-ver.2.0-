import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/database/app_db.dart';
import 'package:pdf_viewer/services/app_backup_service.dart';

void main() {
  test(
    'WAL snapshot restores into a validated database and preserves previous state',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'pdf-viewer-backup-',
      );
      final live = File('${directory.path}/live.sqlite');
      final snapshot = File('${directory.path}/snapshot.sqlite');
      final db = AppDb.forExecutor(NativeDatabase(live));
      var closed = false;
      addTearDown(() async {
        if (!closed) await db.close();
        await directory.delete(recursive: true);
      });
      final service = AppBackupService(db);
      await db.customStatement('PRAGMA wal_autocheckpoint=0');
      await db.customStatement(
        "INSERT INTO tags(name,category) VALUES('before',4)",
      );
      await service.exportDatabaseTo(snapshot);
      await db.customStatement(
        "INSERT INTO tags(name,category) VALUES('after',4)",
      );
      expect(await service.restoreDatabaseFrom(snapshot, live), isTrue);
      closed = true;
      final restored = AppDb.forExecutor(NativeDatabase(live));
      expect(
        (await restored.customSelect('SELECT name FROM tags').get()).map(
          (r) => r.read<String>('name'),
        ),
        ['before'],
      );
      await restored.close();
      final previous =
          (await directory
                  .list()
                  .where((f) => f.path.contains('.previous_'))
                  .toList())
              .single;
      final rollback = AppDb.forExecutor(NativeDatabase(File(previous.path)));
      expect(
        (await rollback.customSelect('SELECT name FROM tags').get()).length,
        2,
      );
      await rollback.close();
    },
  );

  test(
    'invalid restore is rejected before the live database is closed or changed',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'pdf-viewer-invalid-',
      );
      final live = File('${directory.path}/live.sqlite');
      final bad = File('${directory.path}/bad.sqlite');
      await bad.writeAsString('incomplete SQLite copy');
      final db = AppDb.forExecutor(NativeDatabase(live));
      addTearDown(() async {
        await db.close();
        await directory.delete(recursive: true);
      });
      await db.customStatement(
        "INSERT INTO tags(name,category) VALUES('keep',4)",
      );
      expect(
        await AppBackupService(db).restoreDatabaseFrom(bad, live),
        isFalse,
      );
      expect(
        (await db.customSelect('SELECT name FROM tags').get()).single
            .read<String>('name'),
        'keep',
      );
    },
  );
}
