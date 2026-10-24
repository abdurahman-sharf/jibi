import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/core/models/app_settings.dart';
import 'package:jibi/features/reminders/domain/notification_scheduler.dart';
import 'package:jibi/features/reminders/domain/reminder_planner.dart';

void main() {
  List<DateTime> times(List<PlannedNotification> plan) =>
      [for (final item in plan) item.at];

  test('no reminders when the schedule is off', () {
    expect(
      planBackupReminders(
        schedule: BackupSchedule.off,
        lastBackup: null,
        now: DateTime(2026, 9, 19, 8),
      ),
      isEmpty,
    );
  });

  group('when no backup exists yet', () {
    test('remind today if the reminder hour has not passed', () {
      final plan = planBackupReminders(
        schedule: BackupSchedule.weekly,
        lastBackup: null,
        now: DateTime(2026, 9, 19, 8),
      );

      expect(times(plan), [
        DateTime(2026, 9, 19, 9),
        DateTime(2026, 9, 20, 9),
        DateTime(2026, 9, 21, 9),
      ]);
    });

    test('remind tomorrow once today\'s hour is over', () {
      final plan = planBackupReminders(
        schedule: BackupSchedule.daily,
        lastBackup: null,
        now: DateTime(2026, 9, 19, 9, 30),
      );

      expect(plan.first.at, DateTime(2026, 9, 20, 9));
    });
  });

  group('next due date', () {
    test('daily: the day after the last backup, at the reminder hour', () {
      final plan = planBackupReminders(
        schedule: BackupSchedule.daily,
        lastBackup: DateTime(2026, 9, 18, 20, 15),
        now: DateTime(2026, 9, 19, 7),
      );

      expect(plan.first.at, DateTime(2026, 9, 19, 9));
    });

    test('weekly: seven days after the last backup', () {
      final plan = planBackupReminders(
        schedule: BackupSchedule.weekly,
        lastBackup: DateTime(2026, 9, 16, 12),
        now: DateTime(2026, 9, 19, 12),
      );

      expect(plan.first.at, DateTime(2026, 9, 23, 9));
    });

    test('monthly: same day next month', () {
      final plan = planBackupReminders(
        schedule: BackupSchedule.monthly,
        lastBackup: DateTime(2026, 9, 10, 12),
        now: DateTime(2026, 9, 19, 12),
      );

      expect(plan.first.at, DateTime(2026, 10, 10, 9));
    });

    test('monthly clamps to the last day of a shorter month', () {
      final plan = planBackupReminders(
        schedule: BackupSchedule.monthly,
        lastBackup: DateTime(2026, 1, 31, 12),
        now: DateTime(2026, 2, 1, 12),
      );

      expect(plan.first.at, DateTime(2026, 2, 28, 9));
    });

    test('December rolls into January', () {
      final plan = planBackupReminders(
        schedule: BackupSchedule.monthly,
        lastBackup: DateTime(2026, 12, 15, 12),
        now: DateTime(2026, 12, 20, 12),
      );

      expect(plan.first.at, DateTime(2027, 1, 15, 9));
    });
  });

  test('an overdue backup nags from the next reminder hour', () {
    final plan = planBackupReminders(
      schedule: BackupSchedule.weekly,
      lastBackup: DateTime(2026, 9, 1, 12),
      now: DateTime(2026, 9, 19, 14),
    );

    expect(times(plan), [
      DateTime(2026, 9, 20, 9),
      DateTime(2026, 9, 21, 9),
      DateTime(2026, 9, 22, 9),
    ]);
  });

  test('nag days roll over month ends', () {
    final plan = planBackupReminders(
      schedule: BackupSchedule.daily,
      lastBackup: null,
      now: DateTime(2026, 9, 30, 10),
    );

    expect(times(plan), [
      DateTime(2026, 10, 1, 9),
      DateTime(2026, 10, 2, 9),
      DateTime(2026, 10, 3, 9),
    ]);
  });

  test('custom hour and nag count are respected', () {
    final plan = planBackupReminders(
      schedule: BackupSchedule.daily,
      lastBackup: null,
      now: DateTime(2026, 9, 19, 6),
      hour: 20,
      nagCount: 1,
    );

    expect(times(plan), [DateTime(2026, 9, 19, 20)]);
  });

  test('ids, channel and payload are stable and the text is generic', () {
    final plan = planBackupReminders(
      schedule: BackupSchedule.daily,
      lastBackup: null,
      now: DateTime(2026, 9, 19, 6),
    );

    expect([for (final item in plan) item.id], [1, 2, 3]);
    for (final item in plan) {
      expect(item.payload, backupReminderPayload);
      expect(item.channel, ReminderChannel.backup);
      expect(item.title + item.body, isNot(matches(RegExp(r'\d'))));
    }
  });

  test('identical plans compare equal so nothing is rescheduled needlessly', () {
    List<PlannedNotification> plan() => planBackupReminders(
      schedule: BackupSchedule.weekly,
      lastBackup: DateTime(2026, 9, 10),
      now: DateTime(2026, 9, 19, 6),
    );

    expect(plan(), plan());
    expect(plan().toSet(), plan().toSet());
  });
}
