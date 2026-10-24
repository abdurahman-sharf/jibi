import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/app/jibi_app.dart';
import 'package:jibi/app/jibi_application.dart';
import 'package:jibi/core/security/security.dart';

import '../support/memory_keys.dart' show MemoryKeys, NoBiometrics;

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
  });
}

void main() {
  late Directory directory;
  late JibiApplication app;

  setUp(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  Future<void> createApp(WidgetTester tester) async {
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('jibi-hold-');
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
  }

  Future<void> openUnlockedShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      JibiApp(application: app, initialView: JibiInitialView.shell),
    );
    await _settle(tester);
    await tester.runAsync(() => app.security.unlockWithPin('123456'));
    await _settle(tester);
    expect(find.text('جيبي مقفل'), findsNothing);
  }

  Future<void> tearDownApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await app.dispose();
      await directory.delete(recursive: true);
    });
  }

  testWidgets('the guard stays on until the app is foregrounded again', (
    tester,
  ) async {
    await createApp(tester);

    expect(app.isExternalActivityInProgress, isFalse);
    await app.runExternalActivity(() async => 1);
    expect(app.isExternalActivityInProgress, isFalse);

    await app.runExternalActivity(() async => 1, holdUntilResumed: true);
    expect(app.isExternalActivityInProgress, isTrue);

    app.releaseHeldExternalActivities();
    expect(app.isExternalActivityInProgress, isFalse);
    // Releasing twice must never push the counter negative.
    app.releaseHeldExternalActivities();
    expect(app.isExternalActivityInProgress, isFalse);

    await tearDownApp(tester);
  });

  testWidgets('a failing action never leaves the guard held', (tester) async {
    await createApp(tester);

    await expectLater(
      app.runExternalActivity<void>(
        () async => throw StateError('share failed'),
        holdUntilResumed: true,
      ),
      throwsStateError,
    );

    expect(app.isExternalActivityInProgress, isFalse);
    await tearDownApp(tester);
  });

  testWidgets(
    'a share sheet that pauses the app after the call returned does not lock',
    (tester) async {
      await createApp(tester);
      await openUnlockedShell(tester);

      // The platform call returns first, the app is paused afterwards: the
      // exact ordering that used to trigger the privacy screen and the lock.
      await tester.runAsync(
        () => app.runExternalActivity(() async {}, holdUntilResumed: true),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      final privacyScreen = find.byWidgetPredicate(
        (widget) =>
            widget is Icon && widget.icon == Icons.lock_outline && widget.size == 48,
      );
      expect(privacyScreen, findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _settle(tester);

      expect(find.text('جيبي مقفل'), findsNothing);
      expect(app.isExternalActivityInProgress, isFalse);

      // Once released, backgrounding locks again as usual.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _settle(tester);
      expect(find.text('جيبي مقفل'), findsOneWidget);

      await tearDownApp(tester);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
