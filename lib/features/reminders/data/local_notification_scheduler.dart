import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../domain/notification_scheduler.dart';

/// [NotificationScheduler] on top of `flutter_local_notifications` (Android).
///
/// Times are scheduled as absolute instants (UTC), so no time-zone database is
/// needed, and with the inexact-while-idle mode no exact-alarm permission is
/// requested. Titles and bodies come from the planner and are generic: the
/// plugin keeps them unencrypted so it can re-post them after a reboot.
final class LocalNotificationScheduler implements NotificationScheduler {
  LocalNotificationScheduler({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  final StreamController<String> _taps = StreamController<String>.broadcast();
  Future<void>? _initialization;
  Set<PlannedNotification> _lastPlan = const {};
  bool _launchPayloadTaken = false;

  static const _channels = {
    ReminderChannel.backup: AndroidNotificationChannel(
      'jibi_backup_reminders',
      'تذكير النسخ الاحتياطي',
      description: 'تذكير دوري بإنشاء نسخة احتياطية مشفرة.',
    ),
  };

  Future<void> _ensureInitialized() => _initialization ??= _plugin
      .initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('ic_stat_jibi'),
        ),
        onDidReceiveNotificationResponse: (response) {
          final payload = response.payload;
          if (payload != null && payload.isNotEmpty) {
            _taps.add(payload);
          }
        },
      )
      .then<void>((_) {});

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  @override
  Stream<String> get taps => _taps.stream;

  @override
  Future<bool> isPermitted() async {
    try {
      await _ensureInitialized();
      return await _android?.areNotificationsEnabled() ?? false;
    } on Object catch (error) {
      debugPrint('Jibi notifications unavailable: ${error.runtimeType}');
      return false;
    }
  }

  @override
  Future<bool> requestPermission() async {
    try {
      await _ensureInitialized();
      return await _android?.requestNotificationsPermission() ?? false;
    } on Object catch (error) {
      debugPrint('Jibi notification permission failed: ${error.runtimeType}');
      return false;
    }
  }

  @override
  Future<void> replaceAll(Iterable<PlannedNotification> planned) async {
    final plan = planned.toSet();
    try {
      await _ensureInitialized();
      final pending = await _plugin.pendingNotificationRequests();
      final pendingIds = {for (final request in pending) request.id};
      final wantedIds = {for (final item in plan) item.id};
      for (final id in pendingIds.difference(wantedIds)) {
        await _plugin.cancel(id: id);
      }
      final unchanged =
          plan.length == _lastPlan.length &&
          plan.every(_lastPlan.contains) &&
          wantedIds.every(pendingIds.contains);
      if (unchanged) {
        return;
      }
      final now = DateTime.now();
      for (final item in plan) {
        // The plugin rejects moments that already passed; skip those and keep
        // scheduling the rest.
        if (!item.at.isAfter(now)) {
          continue;
        }
        try {
          await _plugin.zonedSchedule(
            id: item.id,
            scheduledDate: tz.TZDateTime.from(item.at.toUtc(), tz.UTC),
            notificationDetails: NotificationDetails(
              android: _androidDetails(item.channel),
            ),
            androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
            title: item.title,
            body: item.body,
            payload: item.payload,
          );
        } on Object catch (error) {
          debugPrint('Jibi could not schedule ${item.id}: ${error.runtimeType}');
        }
      }
      _lastPlan = plan;
    } on Object catch (error) {
      debugPrint('Jibi could not schedule reminders: ${error.runtimeType}');
    }
  }

  @override
  Future<void> cancelAll() async {
    try {
      await _ensureInitialized();
      await _plugin.cancelAll();
      _lastPlan = const {};
    } on Object catch (error) {
      debugPrint('Jibi could not cancel reminders: ${error.runtimeType}');
    }
  }

  @override
  Future<String?> takeLaunchPayload() async {
    if (_launchPayloadTaken) {
      return null;
    }
    _launchPayloadTaken = true;
    try {
      await _ensureInitialized();
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details == null || !details.didNotificationLaunchApp) {
        return null;
      }
      return details.notificationResponse?.payload;
    } on Object {
      return null;
    }
  }

  static AndroidNotificationDetails _androidDetails(ReminderChannel channel) {
    final definition = _channels[channel]!;
    return AndroidNotificationDetails(
      definition.id,
      definition.name,
      channelDescription: definition.description,
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      // Hide the text on a locked screen; the user sees a generic icon only.
      visibility: NotificationVisibility.private,
    );
  }
}
