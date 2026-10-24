import 'dart:io';

import '../models/app_settings.dart';

bool shouldRunBackup({
  required BackupSchedule schedule,
  required DateTime? lastRun,
  required DateTime now,
}) {
  if (schedule == BackupSchedule.off) {
    return false;
  }
  if (lastRun == null) {
    return true;
  }
  if (!now.isAfter(lastRun)) {
    return false;
  }
  switch (schedule) {
    case BackupSchedule.off:
      return false;
    case BackupSchedule.daily:
      return now.year != lastRun.year ||
          now.month != lastRun.month ||
          now.day != lastRun.day;
    case BackupSchedule.weekly:
      return now.difference(lastRun) >= const Duration(days: 7);
    case BackupSchedule.monthly:
      return now.year != lastRun.year || now.month != lastRun.month;
  }
}

/// File name offered to the share sheet / Files picker for a backup ZIP.
String backupShareName(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return 'Jibi_Backup_${time.year}-${two(time.month)}-${two(time.day)}_'
      '${two(time.hour)}${two(time.minute)}.zip';
}

const _rollbackPrefix = 'before_restore_';

/// True for user-visible encrypted backups. Safety copies created before a
/// restore are never listed, pruned, or counted as "the last backup".
bool isListedBackup(FileSystemEntity entity) =>
    entity is File &&
    entity.path.endsWith('.jibi') &&
    !entity.uri.pathSegments.last.startsWith(_rollbackPrefix);

/// Moves safety copies left in [from] by older builds into [to].
Future<void> moveRollbackBackups({
  required Directory from,
  required Directory to,
}) async {
  if (!await from.exists()) {
    return;
  }
  await for (final entity in from.list(followLinks: false)) {
    if (entity is! File ||
        !entity.uri.pathSegments.last.startsWith(_rollbackPrefix)) {
      continue;
    }
    try {
      await to.create(recursive: true);
      await entity.rename(
        '${to.path}${Platform.pathSeparator}${entity.uri.pathSegments.last}',
      );
    } on FileSystemException {
      // Leave it in place; it is only hidden from the list, never deleted.
    }
  }
}

Future<List<File>> pruneOldBackups({
  required Directory directory,
  required int retentionCount,
}) async {
  final effectiveRetention = retentionCount < 1 ? 1 : retentionCount;
  if (!await directory.exists()) {
    return const <File>[];
  }
  final backups = <File>[];
  await for (final entity in directory.list(followLinks: false)) {
    if (isListedBackup(entity)) {
      backups.add(entity as File);
    }
  }
  backups.sort((left, right) {
    final leftModified = left.lastModifiedSync();
    final rightModified = right.lastModifiedSync();
    final time = rightModified.compareTo(leftModified);
    return time != 0 ? time : right.path.compareTo(left.path);
  });
  if (backups.length <= effectiveRetention) {
    return const <File>[];
  }
  final overflow = backups.sublist(effectiveRetention);
  for (final file in overflow) {
    await file.delete();
  }
  return List<File>.unmodifiable(overflow);
}

Future<DateTime?> lastLocalBackupTime(Directory directory) async {
  if (!await directory.exists()) {
    return null;
  }
  DateTime? latest;
  await for (final entity in directory.list(followLinks: false)) {
    if (isListedBackup(entity)) {
      final modified = await (entity as File).lastModified();
      if (latest == null || modified.isAfter(latest)) {
        latest = modified;
      }
    }
  }
  return latest;
}
