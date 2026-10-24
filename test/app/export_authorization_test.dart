import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/app/jibi_application.dart';
import 'package:jibi/core/security/security.dart';

import '../support/memory_keys.dart' show MemoryKeys;

/// A fingerprint sensor that answers as told and counts its prompts.
class _Sensor implements BiometricAuthenticator {
  _Sensor({this.enrolled = true, this.accepts = true, this.throws = false});

  final bool enrolled;
  final bool accepts;
  final bool throws;
  int prompts = 0;

  @override
  Future<bool> authenticate({required String reason}) async {
    prompts += 1;
    if (throws) throw PlatformException(code: 'boom');
    return enrolled && accepts;
  }

  @override
  Future<bool> canAuthenticate() async => enrolled;
}

/// The fingerprint step of the export gate: shown first when it can be, and
/// never a way to skip the PIN when it cannot confirm.
void main() {
  late Directory directory;
  late JibiApplication app;
  late AesGcmSecurityService security;

  setUp(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  Future<void> createApp(
    WidgetTester tester,
    _Sensor sensor, {
    required bool biometricsEnabled,
  }) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.jibi.jibi/screen_protection'),
      (_) async => null,
    );
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('jibi-export-auth-');
      security = AesGcmSecurityService(
        keyStore: MemoryKeys(),
        biometricAuthenticator: sensor,
      );
      await security.initialize(pin: '123456');
      app = await JibiApplication.create(
        directory: directory,
        securityService: security,
      );
      await app.saveSettings(
        app.settings.copyWith(biometricsEnabled: biometricsEnabled),
      );
    });
  }

  Future<void> tearDownApp(WidgetTester tester) async {
    await tester.runAsync(() async {
      await app.dispose();
      await directory.delete(recursive: true);
    });
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.jibi.jibi/screen_protection'),
      null,
    );
  }

  testWidgets('a confirmed fingerprint passes and the app stays unlocked', (
    tester,
  ) async {
    final sensor = _Sensor();
    await createApp(tester, sensor, biometricsEnabled: true);
    addTearDown(() => tearDownApp(tester));

    final result = await tester.runAsync(app.confirmWithBiometrics);

    expect(result, isTrue);
    expect(sensor.prompts, 1);
    // The gate never lets the lock state slip, and releases its guard.
    expect(app.isExternalActivityInProgress, isFalse);
    final sealed = await tester.runAsync(() => security.encryptText('x'));
    expect(sealed, isNotNull);
  });

  testWidgets('a declined fingerprint reports false so the PIN is asked', (
    tester,
  ) async {
    final sensor = _Sensor(accepts: false);
    await createApp(tester, sensor, biometricsEnabled: true);
    addTearDown(() => tearDownApp(tester));

    expect(await tester.runAsync(app.confirmWithBiometrics), isFalse);
    expect(sensor.prompts, 1);
    expect(app.isExternalActivityInProgress, isFalse);
  });

  testWidgets('a sensor that fails is treated as declined, never as a pass', (
    tester,
  ) async {
    final sensor = _Sensor(throws: true);
    await createApp(tester, sensor, biometricsEnabled: true);
    addTearDown(() => tearDownApp(tester));

    expect(await tester.runAsync(app.confirmWithBiometrics), isFalse);
    expect(app.isExternalActivityInProgress, isFalse);
  });

  testWidgets('with biometrics turned off the fingerprint is not even tried', (
    tester,
  ) async {
    final sensor = _Sensor();
    await createApp(tester, sensor, biometricsEnabled: false);
    addTearDown(() => tearDownApp(tester));

    expect(await tester.runAsync(app.confirmWithBiometrics), isNull);
    expect(sensor.prompts, 0);
  });

  testWidgets('with no fingerprint enrolled it goes straight to the PIN', (
    tester,
  ) async {
    final sensor = _Sensor(enrolled: false);
    await createApp(tester, sensor, biometricsEnabled: true);
    addTearDown(() => tearDownApp(tester));

    expect(await tester.runAsync(app.confirmWithBiometrics), isNull);
    expect(sensor.prompts, 0);
  });
}
