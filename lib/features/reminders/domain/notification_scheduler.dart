/// Which Android notification channel a reminder belongs to.
enum ReminderChannel { backup }

/// A notification the app wants pending at a given moment. Equality covers
/// every field, so two identical plans are recognised as "nothing to do".
final class PlannedNotification {
  const PlannedNotification({
    required this.id,
    required this.at,
    required this.title,
    required this.body,
    required this.payload,
    this.channel = ReminderChannel.backup,
  });

  final int id;

  /// Local wall-clock time at which the notification should appear.
  final DateTime at;
  final String title;
  final String body;

  /// Opaque routing token handed back when the notification is tapped. It
  /// never contains amounts or names.
  final String payload;
  final ReminderChannel channel;

  @override
  bool operator ==(Object other) =>
      other is PlannedNotification &&
      other.id == id &&
      other.at == at &&
      other.title == title &&
      other.body == body &&
      other.payload == payload &&
      other.channel == channel;

  @override
  int get hashCode => Object.hash(id, at, title, body, payload, channel);

  @override
  String toString() => 'PlannedNotification($id, $at, $payload)';
}

/// Boundary around the OS notification service, so tests never need the
/// platform plugin.
abstract interface class NotificationScheduler {
  /// Whether the user has allowed notifications right now.
  Future<bool> isPermitted();

  /// Asks for permission when needed and reports the outcome.
  Future<bool> requestPermission();

  /// Makes exactly [planned] pending: schedules what is new or changed and
  /// cancels everything else this app scheduled.
  Future<void> replaceAll(Iterable<PlannedNotification> planned);

  Future<void> cancelAll();

  /// Payloads of notifications tapped while the app is running.
  Stream<String> get taps;

  /// The payload that launched the app from a tapped notification, once.
  Future<String?> takeLaunchPayload();
}

/// Used where no platform scheduler exists (tests, unsupported platforms).
final class NoopNotificationScheduler implements NotificationScheduler {
  const NoopNotificationScheduler();

  @override
  Future<bool> isPermitted() async => false;

  @override
  Future<bool> requestPermission() async => false;

  @override
  Future<void> replaceAll(Iterable<PlannedNotification> planned) async {}

  @override
  Future<void> cancelAll() async {}

  @override
  Stream<String> get taps => const Stream<String>.empty();

  @override
  Future<String?> takeLaunchPayload() async => null;
}
