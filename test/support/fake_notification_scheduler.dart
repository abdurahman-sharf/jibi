import 'dart:async';

import 'package:jibi/features/reminders/domain/notification_scheduler.dart';

/// In-memory scheduler that records every plan it was asked to make pending.
final class FakeNotificationScheduler implements NotificationScheduler {
  FakeNotificationScheduler({this.permitted = true, this.launchPayload});

  bool permitted;
  bool grantOnRequest = true;
  String? launchPayload;
  int permissionRequests = 0;
  int cancelAllCalls = 0;
  final List<Set<PlannedNotification>> plans = [];
  final StreamController<String> _taps = StreamController<String>.broadcast();

  /// What is currently pending (the last plan, as a real scheduler would hold).
  Set<PlannedNotification> get pending => plans.isEmpty ? {} : plans.last;

  /// Simulates the user tapping a notification while the app is running.
  void tap(String payload) => _taps.add(payload);

  @override
  Future<bool> isPermitted() async => permitted;

  @override
  Future<bool> requestPermission() async {
    permissionRequests += 1;
    if (grantOnRequest) permitted = true;
    return permitted;
  }

  @override
  Future<void> replaceAll(Iterable<PlannedNotification> planned) async {
    plans.add(planned.toSet());
  }

  @override
  Future<void> cancelAll() async {
    cancelAllCalls += 1;
    plans.add({});
  }

  @override
  Stream<String> get taps => _taps.stream;

  @override
  Future<String?> takeLaunchPayload() async {
    final payload = launchPayload;
    launchPayload = null;
    return payload;
  }
}
