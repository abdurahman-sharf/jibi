import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/app/book/book_export_scope.dart';
import 'package:jibi/app/jibi_app.dart';
import 'package:jibi/app/jibi_application.dart';
import 'package:jibi/core/security/security.dart';

import '../support/memory_keys.dart' show MemoryKeys;

class _Sensor implements BiometricAuthenticator {
  _Sensor({this.accepts = true});

  bool accepts;
  int prompts = 0;

  @override
  Future<bool> authenticate({required String reason}) async {
    prompts += 1;
    return accepts;
  }

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

/// The real gate in front of every report export and share (`JibiApp` supplies
/// it through `BookExportScope`): the fingerprint first, the PIN as the way
/// back.
void main() {
  late Directory directory;
  late JibiApplication app;

  setUp(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  /// Opens the app unlocked and returns the export gate the reports use.
  Future<ExportAuthorizer> openApp(
    WidgetTester tester,
    _Sensor sensor, {
    bool biometricsEnabled = true,
  }) async {
    // The lock screen may try the fingerprint on its own while the app opens,
    // so the sensor accepts until the app is unlocked and only then answers
    // as the test wants.
    final wanted = sensor.accepts;
    sensor.accepts = true;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.jibi.jibi/screen_protection'),
      (_) async => null,
    );
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('jibi-export-gate-');
      final security = AesGcmSecurityService(
        keyStore: MemoryKeys(),
        biometricAuthenticator: sensor,
      );
      await security.initialize(pin: '123456');
      // Starts locked, like a real launch, so unlocking is a visible change.
      await security.lock();
      app = await JibiApplication.create(
        directory: directory,
        securityService: security,
      );
      await app.saveSettings(
        app.settings.copyWith(biometricsEnabled: biometricsEnabled),
      );
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await app.dispose();
        await directory.delete(recursive: true);
      });
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('com.jibi.jibi/screen_protection'),
        null,
      );
    });
    await tester.pumpWidget(
      JibiApp(application: app, initialView: JibiInitialView.shell),
    );
    await _settle(tester);
    if (find.text('جيبي مقفل').evaluate().isNotEmpty) {
      await tester.runAsync(() => app.security.unlockWithPin('123456'));
      await _settle(tester);
    }
    expect(find.text('جيبي مقفل'), findsNothing);
    sensor
      ..accepts = wanted
      ..prompts = 0;
    final context = tester.element(find.byType(Scaffold).first);
    return BookExportScope.maybeOf(context)!;
  }

  /// Starts the gate and lets its real async work run until it is waiting on
  /// the user (or finished).
  Future<Future<bool>> startGate(
    WidgetTester tester,
    ExportAuthorizer authorize,
  ) async {
    final context = tester.element(find.byType(Scaffold).first);
    late Future<bool> pending;
    await tester.runAsync(() async {
      pending = authorize(context, title: 'تصدير التقرير');
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump(const Duration(milliseconds: 300));
    return pending;
  }

  Finder pinField() => find.byKey(const Key('pin-prompt-input'));

  testWidgets('a confirmed fingerprint exports without any PIN prompt', (
    tester,
  ) async {
    final sensor = _Sensor();
    final authorize = await openApp(tester, sensor);

    final pending = await startGate(tester, authorize);

    expect(pinField(), findsNothing);
    expect(await tester.runAsync(() => pending), isTrue);
    expect(sensor.prompts, 1);
  });

  testWidgets('a declined fingerprint falls back to the PIN, which must be right', (
    tester,
  ) async {
    final sensor = _Sensor(accepts: false);
    final authorize = await openApp(tester, sensor);

    final pending = await startGate(tester, authorize);
    expect(sensor.prompts, 1);
    expect(pinField(), findsOneWidget);
    expect(find.textContaining('لم يتم التحقق بالبصمة'), findsOneWidget);

    await tester.enterText(pinField(), '654321');
    await tester.tap(find.text('متابعة'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(await tester.runAsync(() => pending), isFalse);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('رمز PIN غير صحيح.'), findsOneWidget);

    // Again, with the right PIN.
    final again = await startGate(tester, authorize);
    await tester.enterText(pinField(), '123456');
    await tester.tap(find.text('متابعة'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(await tester.runAsync(() => again), isTrue);
  });

  testWidgets('with biometrics off the PIN is asked at once', (tester) async {
    final sensor = _Sensor();
    final authorize = await openApp(tester, sensor, biometricsEnabled: false);

    final pending = await startGate(tester, authorize);

    expect(sensor.prompts, 0);
    expect(pinField(), findsOneWidget);
    expect(find.textContaining('لم يتم التحقق بالبصمة'), findsNothing);
    expect(find.text('أدخل رمز PIN لتصدير البيانات أو مشاركتها.'), findsOneWidget);

    await tester.tap(find.text('إلغاء'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(await tester.runAsync(() => pending), isFalse);
  });
}
