import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/core/models/app_settings.dart';
import 'package:jibi/features/home/domain/backup_status.dart';
import 'package:jibi/features/reminders/domain/reminder_planner.dart';
import 'package:jibi/features/reminders/reminder_coordinator.dart';

import '../../support/fake_notification_scheduler.dart';

void main() {
  final now = DateTime(2026, 9, 19, 8);

  ReminderCoordinator build({
    required FakeNotificationScheduler scheduler,
    required AppSettings Function() settings,
    Future<BackupStatus> Function()? status,
  }) => ReminderCoordinator(
    scheduler: scheduler,
    readSettings: settings,
    readBackupStatus:
        status ??
        () async => BackupStatus(lastBackupAt: DateTime(2026, 9, 16), due: false),
    clock: () => now,
  );

  test('a schedule turns into the planned reminders', () async {
    final scheduler = FakeNotificationScheduler();
    final coordinator = build(
      scheduler: scheduler,
      settings: () => AppSettings(
        defaultCurrencyCode: 'SAR',
        backupSchedule: BackupSchedule.weekly,
      ),
    );

    await coordinator.sync();

    expect(
      scheduler.pending,
      planBackupReminders(
        schedule: BackupSchedule.weekly,
        lastBackup: DateTime(2026, 9, 16),
        now: now,
      ).toSet(),
    );
    expect(scheduler.pending, hasLength(3));
  });

  test('turning the schedule off clears the reminders', () async {
    final scheduler = FakeNotificationScheduler();
    var schedule = BackupSchedule.daily;
    final coordinator = build(
      scheduler: scheduler,
      settings: () =>
          AppSettings(defaultCurrencyCode: 'SAR', backupSchedule: schedule),
    );
    await coordinator.sync();
    expect(scheduler.pending, isNotEmpty);

    schedule = BackupSchedule.off;
    await coordinator.sync();

    expect(scheduler.pending, isEmpty);
  });

  test('nothing is scheduled while notifications are not permitted', () async {
    final scheduler = FakeNotificationScheduler(permitted: false);
    final coordinator = build(
      scheduler: scheduler,
      settings: () => AppSettings(
        defaultCurrencyCode: 'SAR',
        backupSchedule: BackupSchedule.daily,
      ),
    );

    await coordinator.sync();

    expect(scheduler.plans, isEmpty);
  });

  test('a new backup moves the reminders forward', () async {
    final scheduler = FakeNotificationScheduler();
    var lastBackup = DateTime(2026, 9, 1);
    final coordinator = build(
      scheduler: scheduler,
      settings: () => AppSettings(
        defaultCurrencyCode: 'SAR',
        backupSchedule: BackupSchedule.weekly,
      ),
      status: () async => BackupStatus(lastBackupAt: lastBackup, due: true),
    );
    await coordinator.sync();
    final overdue = scheduler.pending.map((item) => item.at).reduce(
      (a, b) => a.isBefore(b) ? a : b,
    );
    expect(overdue, DateTime(2026, 9, 19, 9), reason: 'overdue: next reminder hour');

    lastBackup = DateTime(2026, 9, 19, 7);
    await coordinator.sync();

    final next = scheduler.pending.map((item) => item.at).reduce(
      (a, b) => a.isBefore(b) ? a : b,
    );
    expect(next, DateTime(2026, 9, 26, 9));
  });

  test('a failing reader is logged, never thrown, and later syncs still run', () async {
    final scheduler = FakeNotificationScheduler();
    var fail = true;
    final coordinator = build(
      scheduler: scheduler,
      settings: () => AppSettings(
        defaultCurrencyCode: 'SAR',
        backupSchedule: BackupSchedule.daily,
      ),
      status: () async {
        if (fail) throw StateError('disk unavailable');
        return const BackupStatus(lastBackupAt: null, due: true);
      },
    );

    await coordinator.sync();
    expect(scheduler.plans, isEmpty);

    fail = false;
    await coordinator.sync();
    expect(scheduler.pending, isNotEmpty);
  });

  test('overlapping syncs run one after another', () async {
    final scheduler = FakeNotificationScheduler();
    final order = <String>[];
    final coordinator = build(
      scheduler: scheduler,
      settings: () => AppSettings(
        defaultCurrencyCode: 'SAR',
        backupSchedule: BackupSchedule.daily,
      ),
      status: () async {
        order.add('read');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        order.add('done');
        return const BackupStatus(lastBackupAt: null, due: true);
      },
    );

    await Future.wait([coordinator.sync(), coordinator.sync()]);

    expect(order, ['read', 'done', 'read', 'done']);
    expect(scheduler.plans, hasLength(2));
  });
}
