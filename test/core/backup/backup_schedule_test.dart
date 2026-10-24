import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jibi/core/backup/backup_schedule.dart';
import 'package:jibi/core/models/app_settings.dart';

void main() {
  test('shouldRunBackup respects off schedule', () {
    expect(
      shouldRunBackup(
        schedule: BackupSchedule.off,
        lastRun: null,
        now: DateTime.utc(2026, 9, 10),
      ),
      isFalse,
    );
    expect(
      shouldRunBackup(
        schedule: BackupSchedule.off,
        lastRun: DateTime.utc(2020),
        now: DateTime.utc(2026, 9, 10),
      ),
      isFalse,
    );
  });

  test('shouldRunBackup runs once when never run before', () {
    expect(
      shouldRunBackup(
        schedule: BackupSchedule.daily,
        lastRun: null,
        now: DateTime.utc(2026, 9, 10),
      ),
      isTrue,
    );
    expect(
      shouldRunBackup(
        schedule: BackupSchedule.weekly,
        lastRun: null,
        now: DateTime.utc(2026, 9, 10),
      ),
      isTrue,
    );
    expect(
      shouldRunBackup(
        schedule: BackupSchedule.monthly,
        lastRun: null,
        now: DateTime.utc(2026, 9, 10),
      ),
      isTrue,
    );
  });

  test('shouldRunBackup follows daily weekly monthly cadence', () {
    expect(
      shouldRunBackup(
        schedule: BackupSchedule.daily,
        lastRun: DateTime.utc(2026, 9, 10, 8),
        now: DateTime.utc(2026, 9, 10, 20),
      ),
      isFalse,
    );
    expect(
      shouldRunBackup(
        schedule: BackupSchedule.daily,
        lastRun: DateTime.utc(2026, 9, 9, 20),
        now: DateTime.utc(2026, 9, 10, 8),
      ),
      isTrue,
    );
    expect(
      shouldRunBackup(
        schedule: BackupSchedule.weekly,
        lastRun: DateTime.utc(2026, 9, 4),
        now: DateTime.utc(2026, 9, 10),
      ),
      isFalse,
    );
    expect(
      shouldRunBackup(
        schedule: BackupSchedule.weekly,
        lastRun: DateTime.utc(2026, 9, 2),
        now: DateTime.utc(2026, 9, 10),
      ),
      isTrue,
    );
    expect(
      shouldRunBackup(
        schedule: BackupSchedule.monthly,
        lastRun: DateTime.utc(2026, 8, 10),
        now: DateTime.utc(2026, 9, 10),
      ),
      isTrue,
    );
    expect(
      shouldRunBackup(
        schedule: BackupSchedule.monthly,
        lastRun: DateTime.utc(2026, 9, 1),
        now: DateTime.utc(2026, 9, 10),
      ),
      isFalse,
    );
  });

  test('pruneOldBackups keeps newest N jibi files', () async {
    final directory = await Directory.systemTemp.createTemp('jibi-prune-');
    try {
      for (var index = 0; index < 7; index++) {
        final file = File(
          '${directory.path}${Platform.pathSeparator}backup_$index.jibi',
        );
        await file.writeAsString('backup $index');
        await file.setLastModified(DateTime.utc(2026, 9, index + 1));
      }
      await File(
        '${directory.path}${Platform.pathSeparator}notes.txt',
      ).writeAsString('keep me');

      final deleted = await pruneOldBackups(
        directory: directory,
        retentionCount: 5,
      );

      final remaining =
          directory
              .listSync()
              .whereType<File>()
              .where((file) => file.path.endsWith('.jibi'))
              .toList();
      expect(remaining.length, 5);
      expect(deleted.length, 2);
      expect(
        remaining.any((file) => file.path.endsWith('backup_0.jibi')),
        isFalse,
      );
      expect(
        remaining.any((file) => file.path.endsWith('backup_1.jibi')),
        isFalse,
      );
      expect(
        File(
          '${directory.path}${Platform.pathSeparator}notes.txt',
        ).existsSync(),
        isTrue,
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });

  group('restore safety copies', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('jibi-rollback-');
    });

    tearDown(() async {
      await directory.delete(recursive: true);
    });

    File write(Directory folder, String name, DateTime modified) {
      final file = File('${folder.path}${Platform.pathSeparator}$name')
        ..createSync(recursive: true)
        ..writeAsBytesSync(const [1]);
      file.setLastModifiedSync(modified);
      return file;
    }

    test('are neither listed, pruned, nor counted as the last backup', () async {
      write(directory, 'jibi_backup_1.jibi', DateTime.utc(2026, 9, 1));
      final rollback = write(
        directory,
        'before_restore_1.jibi',
        DateTime.utc(2026, 9, 9),
      );

      expect(isListedBackup(File(rollback.path)), isFalse);
      expect(
        (await lastLocalBackupTime(directory))?.toUtc(),
        DateTime.utc(2026, 9, 1),
        reason: 'a safety copy must not reset the backup reminder',
      );
      final deleted = await pruneOldBackups(
        directory: directory,
        retentionCount: 1,
      );
      expect(deleted, isEmpty);
      expect(rollback.existsSync(), isTrue);
    });

    test('copies left by older builds move into the rollback folder', () async {
      final kept = write(directory, 'jibi_backup_1.jibi', DateTime.utc(2026, 9, 1));
      write(directory, 'before_restore_5.jibi', DateTime.utc(2026, 9, 5));
      final rollbackDir = Directory(
        '${directory.path}${Platform.pathSeparator}rollback',
      );

      await moveRollbackBackups(from: directory, to: rollbackDir);

      expect(
        File(
          '${rollbackDir.path}${Platform.pathSeparator}before_restore_5.jibi',
        ).existsSync(),
        isTrue,
      );
      expect(
        File(
          '${directory.path}${Platform.pathSeparator}before_restore_5.jibi',
        ).existsSync(),
        isFalse,
      );
      expect(kept.existsSync(), isTrue);
    });

    test('moving with nothing to move creates no folder', () async {
      final rollbackDir = Directory(
        '${directory.path}${Platform.pathSeparator}rollback',
      );

      await moveRollbackBackups(from: directory, to: rollbackDir);

      expect(rollbackDir.existsSync(), isFalse);
    });
  });
}
