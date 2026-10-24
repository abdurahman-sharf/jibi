import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/models/app_settings.dart';
import '../home/domain/backup_status.dart';
import 'domain/notification_scheduler.dart';
import 'domain/reminder_planner.dart';

/// Keeps the pending OS notifications in step with the settings and the
/// backups. It derives the whole plan from current state on every [sync], so
/// no call site has to remember individual notifications: a finished backup, a
/// changed schedule, a restore, or simply time passing all just call [sync].
final class ReminderCoordinator {
  ReminderCoordinator({
    required this.scheduler,
    required AppSettings Function() readSettings,
    required Future<BackupStatus> Function() readBackupStatus,
    DateTime Function()? clock,
  }) : _readSettings = readSettings,
       _readBackupStatus = readBackupStatus,
       _clock = clock ?? DateTime.now;

  final NotificationScheduler scheduler;
  final AppSettings Function() _readSettings;
  final Future<BackupStatus> Function() _readBackupStatus;
  final DateTime Function() _clock;

  Future<void> _tail = Future<void>.value();

  /// Recomputes and applies the plan. Calls run one after another and a
  /// failure is logged, never thrown: reminders must not break the app.
  Future<void> sync() {
    final run = _tail.then((_) => _run());
    _tail = run;
    return run;
  }

  Future<void> _run() async {
    try {
      final settings = _readSettings();
      if (settings.backupSchedule == BackupSchedule.off) {
        await scheduler.replaceAll(const []);
        return;
      }
      if (!await scheduler.isPermitted()) {
        return;
      }
      final status = await _readBackupStatus();
      await scheduler.replaceAll(
        planBackupReminders(
          schedule: settings.backupSchedule,
          lastBackup: status.lastBackupAt,
          now: _clock(),
        ),
      );
    } on Object catch (error) {
      debugPrint('Jibi reminder sync failed: ${error.runtimeType}');
    }
  }
}
