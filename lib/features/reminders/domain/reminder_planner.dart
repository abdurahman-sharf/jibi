import '../../../core/models/app_settings.dart';
import 'notification_scheduler.dart';

/// Routing payload of every backup reminder.
const backupReminderPayload = 'backup';

/// Ids 1..3 are reserved for backup reminders.
const _backupReminderBaseId = 1;

/// Plans the backup reminder(s) for the current schedule.
///
/// The first reminder fires when the next backup is due, at [hour] local time.
/// When that moment already passed (or no backup exists) it fires at the next
/// [hour] instead, followed by [nagCount] - 1 daily repeats so a forgotten
/// backup keeps nudging for a few days, but never forever. Every backup made
/// re-plans from the new "last backup" time.
///
/// The text is deliberately generic: notifications may be visible on a locked
/// screen and are stored unencrypted by the platform.
List<PlannedNotification> planBackupReminders({
  required BackupSchedule schedule,
  required DateTime? lastBackup,
  required DateTime now,
  int hour = 9,
  int nagCount = 3,
}) {
  if (schedule == BackupSchedule.off || nagCount < 1) {
    return const [];
  }
  final localNow = now.toLocal();
  var first = lastBackup == null
      ? _todayAt(localNow, hour)
      : _todayAt(_addInterval(lastBackup.toLocal(), schedule), hour);
  if (!first.isAfter(localNow)) {
    final today = _todayAt(localNow, hour);
    first = today.isAfter(localNow)
        ? today
        : DateTime(localNow.year, localNow.month, localNow.day + 1, hour);
  }
  return [
    for (var index = 0; index < nagCount; index++)
      PlannedNotification(
        id: _backupReminderBaseId + index,
        at: DateTime(first.year, first.month, first.day + index, first.hour),
        title: 'جيبي: حان موعد النسخ الاحتياطي',
        body: 'افتح التطبيق وأنشئ نسخة مشفرة لحماية بياناتك.',
        payload: backupReminderPayload,
        channel: ReminderChannel.backup,
      ),
  ];
}

DateTime _todayAt(DateTime day, int hour) =>
    DateTime(day.year, day.month, day.day, hour);

DateTime _addInterval(DateTime from, BackupSchedule schedule) =>
    switch (schedule) {
      BackupSchedule.daily => DateTime(from.year, from.month, from.day + 1),
      BackupSchedule.weekly => DateTime(from.year, from.month, from.day + 7),
      BackupSchedule.monthly => _plusOneMonth(from),
      BackupSchedule.off => from,
    };

/// Same day next month, clamped to the last day (Jan 31 -> Feb 28/29).
DateTime _plusOneMonth(DateTime from) {
  final lastDayOfNext = DateTime(from.year, from.month + 2, 0).day;
  final day = from.day > lastDayOfNext ? lastDayOfNext : from.day;
  return DateTime(from.year, from.month + 1, day);
}
