import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/app/jibi_app.dart';
import 'package:jibi/app/jibi_application.dart';
import 'package:jibi/app/settings/backup_settings_page.dart';
import 'package:jibi/core/backup/backup_schedule.dart';
import 'package:jibi/core/models/app_settings.dart';
import 'package:jibi/core/security/security.dart';
import 'package:jibi/features/reminders/domain/reminder_planner.dart';
import 'package:jibi/shared/theme/jibi_theme.dart';

import '../support/memory_keys.dart' show MemoryKeys, NoBiometrics;
import '../support/fake_notification_scheduler.dart';

class _AlwaysBiometric implements BiometricAuthenticator {
  @override
  Future<bool> authenticate({required String reason}) async => true;

  @override
  Future<bool> canAuthenticate() async => true;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
  });
}

/// Pumps the widget tree while real time passes, until [done] is true.
/// Work that mixes real file IO with widget-driven futures needs both.
Future<void> _waitFor(
  WidgetTester tester,
  bool Function() done, {
  Duration timeout = const Duration(seconds: 90),
}) async {
  await tester.runAsync(() async {
    final deadline = DateTime.now().add(timeout);
    while (!done() && DateTime.now().isBefore(deadline)) {
      // Advance fake time as well, so timers created in the widget zone fire.
      await tester.pump(const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await tester.pump();
  });
}

void main() {
  late Directory directory;
  late JibiApplication app;
  late FakeNotificationScheduler scheduler;

  setUp(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  Future<void> createApp(
    WidgetTester tester, {
    BiometricAuthenticator? biometrics,
    bool locked = false,
    FakeNotificationScheduler? fake,
  }) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    scheduler = fake ?? FakeNotificationScheduler();
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('jibi-remind-');
      final security = AesGcmSecurityService(
        keyStore: MemoryKeys(),
        biometricAuthenticator: biometrics ?? NoBiometrics(),
      );
      await security.initialize(pin: '123456');
      if (locked) await security.lock();
      app = await JibiApplication.create(
        directory: directory,
        securityService: security,
        notificationScheduler: scheduler,
      );
    });
  }

  Future<void> tearDownApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await app.dispose();
      await directory.delete(recursive: true);
    });
  }

  Future<List<File>> backups(WidgetTester tester) async =>
      (await tester.runAsync(() async => [
        for (final entity in app.backupDirectory.listSync())
          if (isListedBackup(entity)) entity as File,
      ]))!;

  group('application', () {
    testWidgets(
      'choosing a schedule plans reminders; a backup moves them forward',
      (tester) async {
        await createApp(tester);
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        });
        expect(scheduler.pending, isEmpty, reason: 'schedule starts off');

        await tester.runAsync(() async {
          await app.saveSettings(
            app.settings.copyWith(backupSchedule: BackupSchedule.weekly),
          );
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        expect(scheduler.pending, hasLength(3));
        expect(
          scheduler.pending.every((item) => item.payload == backupReminderPayload),
          isTrue,
        );
        final beforeBackup = scheduler.pending.map((item) => item.at).reduce(
          (a, b) => a.isBefore(b) ? a : b,
        );

        final backup = await tester.runAsync(() => app.createBackup(pin: '123456'));
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });

        expect(await tester.runAsync(backup!.file.exists), isTrue);
        expect(backup.shareName, startsWith('Jibi_Backup_'));
        final afterBackup = scheduler.pending.map((item) => item.at).reduce(
          (a, b) => a.isBefore(b) ? a : b,
        );
        expect(
          afterBackup.isAfter(beforeBackup),
          isTrue,
          reason: 'the next reminder is a week after the fresh backup',
        );
        await tearDownApp(tester);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    testWidgets(
      'a due backup is created on demand and respects the switch',
      (tester) async {
        await createApp(tester);
        await tester.runAsync(
          () => app.saveSettings(
            app.settings.copyWith(backupSchedule: BackupSchedule.daily),
          ),
        );

        final off = await tester.runAsync(() async {
          await app.saveSettings(
            app.settings.copyWith(autoBackupOnUnlock: false),
          );
          return app.runScheduledBackupIfDue('123456');
        });
        expect(off, isNull, reason: 'the user switched automatic backup off');

        final made = await tester.runAsync(() async {
          await app.saveSettings(
            app.settings.copyWith(autoBackupOnUnlock: true),
          );
          return app.runScheduledBackupIfDue('123456');
        });
        expect(made, isNotNull);
        expect(await backups(tester), hasLength(1));

        final again = await tester.runAsync(
          () => app.runScheduledBackupIfDue('123456'),
        );
        expect(again, isNull, reason: 'not due again right after a backup');
        await tearDownApp(tester);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    testWidgets('no automatic backup when the schedule is off', (tester) async {
      await createApp(tester);

      final result = await tester.runAsync(
        () => app.runScheduledBackupIfDue('123456'),
      );

      expect(result, isNull);
      expect(await backups(tester), isEmpty);
      await tearDownApp(tester);
    });
  });

  group('lock screen', () {
    testWidgets(
      'unlocking with the PIN makes a due backup and says so',
      (tester) async {
        await createApp(tester, locked: true);
        await tester.runAsync(
          () => app.saveSettings(
            app.settings.copyWith(backupSchedule: BackupSchedule.daily),
          ),
        );

        await tester.pumpWidget(
          JibiApp(application: app, initialView: JibiInitialView.shell),
        );
        await _settle(tester);
        expect(find.text('جيبي مقفل'), findsOneWidget);

        await tester.enterText(find.byType(TextField), '123456');
        await tester.tap(find.text('فتح القفل'));
        // PIN check + backup are key-derivation heavy in a debug VM.
        await _waitFor(
          tester,
          () => app.backupDirectory.listSync().any(isListedBackup),
          timeout: const Duration(minutes: 3),
        );
        await _waitFor(
          tester,
          () => find.textContaining('نسخة احتياطية تلقائية').evaluate().isNotEmpty,
        );

        expect(find.text('جيبي مقفل'), findsNothing);
        expect(await backups(tester), hasLength(1));
        expect(find.textContaining('نسخة احتياطية تلقائية'), findsOneWidget);
        expect(find.text('حفظ في Drive'), findsOneWidget);
        await tearDownApp(tester);
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    testWidgets(
      'a biometric unlock never makes a backup (the PIN is not available)',
      (tester) async {
        await createApp(
          tester,
          biometrics: _AlwaysBiometric(),
          locked: true,
        );
        await tester.runAsync(
          () => app.saveSettings(
            app.settings.copyWith(
              backupSchedule: BackupSchedule.daily,
              biometricsEnabled: true,
            ),
          ),
        );

        await tester.pumpWidget(
          JibiApp(application: app, initialView: JibiInitialView.shell),
        );
        await _settle(tester);
        await _settle(tester);
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        });

        expect(find.text('جيبي مقفل'), findsNothing, reason: 'unlocked by finger');
        expect(await backups(tester), isEmpty);
        await tearDownApp(tester);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });

  group('notification taps', () {
    testWidgets(
      'a tap opens the backup screen once the app is unlocked, not before',
      (tester) async {
        await createApp(tester, locked: true);

        await tester.pumpWidget(
          JibiApp(application: app, initialView: JibiInitialView.shell),
        );
        await _settle(tester);
        scheduler.tap(backupReminderPayload);
        await _settle(tester);
        expect(find.text('جيبي مقفل'), findsOneWidget);
        expect(find.byType(BackupSettingsPage), findsNothing);

        await tester.runAsync(() => app.security.unlockWithPin('123456'));
        await _settle(tester);
        await _settle(tester);

        expect(find.byType(BackupSettingsPage), findsOneWidget);
        await tearDownApp(tester);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    testWidgets(
      'launching from a notification opens the backup screen after unlock',
      (tester) async {
        await createApp(
          tester,
          locked: true,
          fake: FakeNotificationScheduler(launchPayload: backupReminderPayload),
        );

        await tester.pumpWidget(
          JibiApp(application: app, initialView: JibiInitialView.shell),
        );
        await _settle(tester);
        expect(find.byType(BackupSettingsPage), findsNothing);

        await tester.runAsync(() => app.security.unlockWithPin('123456'));
        await _settle(tester);
        await _settle(tester);

        expect(find.byType(BackupSettingsPage), findsOneWidget);
        await tearDownApp(tester);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    testWidgets('unknown payloads are ignored', (tester) async {
      await createApp(tester);

      await tester.pumpWidget(
        MaterialApp(
          theme: JibiTheme.light(),
          home: JibiApp(application: app, initialView: JibiInitialView.shell),
        ),
      );
      await _settle(tester);
      scheduler.tap('something-else');
      await _settle(tester);

      expect(find.byType(BackupSettingsPage), findsNothing);
      await tearDownApp(tester);
    });
  });

  group('settings', () {
    Future<void> openSettings(WidgetTester tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: JibiTheme.light(),
            home: Directionality(
              textDirection: TextDirection.rtl,
              child: Material(
                child: BackupSettingsPage(application: app),
              ),
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pump();
      });
      await _settle(tester);
    }

    Future<void> chooseSchedule(WidgetTester tester, String label) async {
      final dropdown = find.text('إيقاف التذكير');
      await tester.ensureVisible(dropdown);
      await tester.tap(dropdown);
      await _settle(tester);
      await tester.tap(find.text(label).last);
      await _settle(tester);
    }

    testWidgets(
      'turning reminders on asks for notification permission and plans them',
      (tester) async {
        await createApp(tester, fake: FakeNotificationScheduler(permitted: false));
        await openSettings(tester);

        await chooseSchedule(tester, 'أسبوعياً');
        await _waitFor(tester, () => scheduler.pending.isNotEmpty);

        expect(scheduler.permissionRequests, 1);
        expect(app.settings.backupSchedule, BackupSchedule.weekly);
        expect(scheduler.pending, hasLength(3));
        expect(find.textContaining('الإشعارات غير مسموحة'), findsNothing);
        await tearDownApp(tester);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    testWidgets(
      'a refused permission keeps the schedule and says reminders stay in-app',
      (tester) async {
        final refusing = FakeNotificationScheduler(permitted: false)
          ..grantOnRequest = false;
        await createApp(tester, fake: refusing);
        await openSettings(tester);

        await chooseSchedule(tester, 'يومياً');
        await _waitFor(tester, () => scheduler.permissionRequests > 0);
        await _settle(tester);

        expect(scheduler.permissionRequests, 1);
        expect(app.settings.backupSchedule, BackupSchedule.daily);
        expect(scheduler.pending, isEmpty);
        expect(find.textContaining('الإشعارات غير مسموحة'), findsOneWidget);
        await tearDownApp(tester);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
