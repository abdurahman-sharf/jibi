import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/app/jibi_app.dart';
import 'package:jibi/app/jibi_application.dart';
import 'package:jibi/core/security/kdf.dart';
import 'package:jibi/core/security/security.dart';

import '../support/memory_keys.dart';

/// Requirement 6/8 of the startup-performance investigation: pressing the
/// unlock button repeatedly must never start a second verification while one
/// is already running, correct/wrong PIN must behave as before, and none of
/// this should regress once `unlockWithPin` was rewritten to batch its
/// secure-storage reads (see `pin_unlock_diagnostics_test.dart` for the
/// service-level half of this).
///
/// Runs the REAL `AesGcmSecurityService` (real 600k-iteration PBKDF2, just an
/// in-memory key store), so each of these genuinely takes a few real seconds —
/// on purpose: a fake that resolves instantly would prove nothing about a
/// double-tap actually landing inside the multi-second verification window.
void main() {
  late Directory directory;
  late JibiApplication app;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() {
    Kdf.useBackgroundIsolate = false;
  });

  Future<void> createLockedApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('jibi-lock-unlock-');
      final security = AesGcmSecurityService(
        keyStore: MemoryKeys(),
        biometricAuthenticator: NoBiometrics(),
      );
      await security.initialize(pin: '123456');
      await security.lock();
      app = await JibiApplication.create(
        directory: directory,
        securityService: security,
      );
    });
    await tester.pumpWidget(
      JibiApp(application: app, initialView: JibiInitialView.shell),
    );
    await tester.pump();
    expect(find.text('جيبي مقفل'), findsOneWidget);
  }

  Future<void> tearDownApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await app.dispose();
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        // Windows keeps SQLite handles briefly after close; the test is done.
      }
    });
  }

  /// Pumps while real time passes, until [done] or [timeout].
  Future<void> waitFor(
    WidgetTester tester,
    bool Function() done, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(timeout);
      while (!done() && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await tester.pump();
    });
  }

  testWidgets(
    'pressing the unlock button twice in quick succession runs PBKDF2 only '
    'once, and still unlocks',
    (tester) async {
      await createLockedApp(tester);
      Kdf.callCount = 0;

      await tester.enterText(find.byKey(const Key('lock-pin')), '123456');
      final button = find.byKey(const Key('lock-unlock-button'));
      // Two rapid presses, with no pump in between — the second lands while
      // the first PBKDF2 derivation is still running on the real code path.
      await tester.tap(button);
      await tester.tap(button);
      await tester.pump();

      await waitFor(tester, () => find.text('جيبي مقفل').evaluate().isEmpty);

      expect(find.text('جيبي مقفل'), findsNothing);
      expect(
        Kdf.callCount,
        1,
        reason: 'the second press must be ignored while the first is in flight',
      );

      await tearDownApp(tester);
    },
  );

  testWidgets('a wrong PIN keeps the app locked and shows an error',
      (tester) async {
    await createLockedApp(tester);

    await tester.enterText(find.byKey(const Key('lock-pin')), '000000');
    await tester.tap(find.byKey(const Key('lock-unlock-button')));
    await tester.pump();
    expect(find.text('جارٍ التحقق…'), findsOneWidget);

    await waitFor(tester, () => find.text('رمز PIN غير صحيح.').evaluate().isNotEmpty);

    expect(find.text('رمز PIN غير صحيح.'), findsOneWidget);
    expect(find.text('جيبي مقفل'), findsOneWidget);

    await tearDownApp(tester);
  });

  testWidgets('a correct PIN unlocks and reaches Home', (tester) async {
    await createLockedApp(tester);

    await tester.enterText(find.byKey(const Key('lock-pin')), '123456');
    await tester.tap(find.byKey(const Key('lock-unlock-button')));
    await tester.pump();

    await waitFor(tester, () => find.text('جيبي مقفل').evaluate().isEmpty);

    expect(find.text('جيبي مقفل'), findsNothing);
    expect(find.text('مرحباً بك في جيبي 👋'), findsOneWidget);

    await tearDownApp(tester);
  });
}
