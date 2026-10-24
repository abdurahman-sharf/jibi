/// What the dashboard banner needs to know about local backups.
final class BackupStatus {
  const BackupStatus({required this.lastBackupAt, required this.due});

  /// Null when no backup has ever been created.
  final DateTime? lastBackupAt;

  /// True when the reminder schedule says a new backup is overdue.
  final bool due;
}
