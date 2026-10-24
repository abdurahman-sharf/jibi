import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/app/jibi_app.dart';
import 'package:jibi/app/jibi_application.dart';
import 'package:jibi/core/security/security.dart';
import 'package:jibi/shared/theme/jibi_theme.dart';
import 'package:jibi/shared/widgets/jibi_onboarding.dart';

import 'support/memory_keys.dart' show MemoryKeys;

class _Biometrics implements BiometricAuthenticator {
  _Biometrics({required this.available, this.result = true});

  final bool available;
  final bool result;
  int prompts = 0;

  @override
  Future<bool> authenticate({required String reason}) async {
    prompts += 1;
    return available && result;
  }

  @override
  Future<bool> canAuthenticate() async => available;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
  });
}

bool _switchValue(WidgetTester tester) =>
    tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value;

void main() {
  testWidgets('onboarding switch defaults on when a biometric is enrolled', (
    tester,
  ) async {
    final changes = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: JibiTheme.light(),
        home: JibiOnboardingFlow(
          biometricAvailability: Future.value(true),
          onBiometricPreferenceChanged: changes.add,
        ),
      ),
    );
    await tester.tap(find.text('ابدأ'));
    await tester.pumpAndSettle();
    // The tour of the features comes before the PIN step.
    await tester.tap(find.byKey(const Key('walkthrough-skip')));
    await tester.pumpAndSettle();

    expect(_switchValue(tester), isTrue);
    expect(changes, [true]);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(_switchValue(tester), isFalse);
    expect(changes, [true, false]);
  });

  testWidgets('a user choice made before availability resolves is kept', (
    tester,
  ) async {
    final availability = Future<bool>.delayed(
      const Duration(milliseconds: 50),
      () => true,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: JibiTheme.light(),
        home: JibiOnboardingFlow(biometricAvailability: availability),
      ),
    );
    // No settling here: the availability check must still be pending when the
    // user touches the switch.
    await tester.tap(find.text('ابدأ'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('walkthrough-skip')));
    await tester.pump();
    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // The user switched it on manually first; availability must not flip it.
    expect(_switchValue(tester), isTrue);
  });

  testWidgets('onboarding switch is disabled without an enrolled biometric', (
    tester,
  ) async {
    final changes = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: JibiTheme.light(),
        home: JibiOnboardingFlow(
          biometricAvailability: Future.value(false),
          onBiometricPreferenceChanged: changes.add,
        ),
      ),
    );
    await tester.tap(find.text('ابدأ'));
    await tester.pumpAndSettle();
    // The tour of the features comes before the PIN step.
    await tester.tap(find.byKey(const Key('walkthrough-skip')));
    await tester.pumpAndSettle();

    final tile = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(tile.value, isFalse);
    expect(tile.onChanged, isNull);
    expect(find.textContaining('غير متاحة'), findsOneWidget);
    expect(changes, [false]);
  });

  group('with a real application', () {
    late Directory directory;

    setUp(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfiNoIsolate;
    });

    void phoneSized(WidgetTester tester) {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    Future<JibiApplication> createApp(
      WidgetTester tester,
      _Biometrics biometrics, {
      bool initialized = false,
      bool biometricsEnabled = false,
    }) async {
      late JibiApplication app;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('jibi-bio-');
        final security = AesGcmSecurityService(
          keyStore: MemoryKeys(),
          biometricAuthenticator: biometrics,
        );
        if (initialized) {
          await security.initialize(pin: '123456');
          await security.lock();
        }
        app = await JibiApplication.create(
          directory: directory,
          securityService: security,
        );
        if (biometricsEnabled) {
          await app.saveSettings(app.settings.copyWith(biometricsEnabled: true));
        }
      });
      return app;
    }

    Future<void> dispose(WidgetTester tester, JibiApplication app) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await app.dispose();
        await directory.delete(recursive: true);
      });
    }

    Future<void> completePinSetup(WidgetTester tester) async {
      await tester.tap(find.text('ابدأ'));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('walkthrough-skip')));
      await _settle(tester);
      await tester.enterText(
        find.widgetWithText(TextField, 'رمز PIN الرئيسي'),
        '123456',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'تأكيد رمز PIN'),
        '123456',
      );
      await tester.tap(find.text('متابعة'));
      await _settle(tester);
    }

    testWidgets(
      'first PIN setup saves biometrics on when enrolled',
      (tester) async {
        phoneSized(tester);
        final app = await createApp(tester, _Biometrics(available: true));

        await tester.pumpWidget(JibiApp(application: app));
        await _settle(tester);
        await completePinSetup(tester);

        expect(app.settings.biometricsEnabled, isTrue);
        await dispose(tester, app);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    testWidgets(
      'first PIN setup keeps biometrics off when none enrolled',
      (tester) async {
        phoneSized(tester);
        final app = await createApp(tester, _Biometrics(available: false));

        await tester.pumpWidget(JibiApp(application: app));
        await _settle(tester);
        await completePinSetup(tester);

        expect(app.settings.biometricsEnabled, isFalse);
        await dispose(tester, app);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    testWidgets(
      'lock screen prompts once and unlocks with the fingerprint',
      (tester) async {
        phoneSized(tester);
        final biometrics = _Biometrics(available: true);
        final app = await createApp(
          tester,
          biometrics,
          initialized: true,
          biometricsEnabled: true,
        );

        await tester.pumpWidget(
          JibiApp(application: app, initialView: JibiInitialView.shell),
        );
        await _settle(tester);
        await _settle(tester);

        expect(biometrics.prompts, 1);
        expect(find.text('جيبي مقفل'), findsNothing);
        await dispose(tester, app);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    testWidgets(
      'a cancelled prompt leaves the PIN field without an error',
      (tester) async {
        phoneSized(tester);
        final biometrics = _Biometrics(available: true, result: false);
        final app = await createApp(
          tester,
          biometrics,
          initialized: true,
          biometricsEnabled: true,
        );

        await tester.pumpWidget(
          JibiApp(application: app, initialView: JibiInitialView.shell),
        );
        await _settle(tester);
        await _settle(tester);

        expect(biometrics.prompts, 1);
        expect(find.text('جيبي مقفل'), findsOneWidget);
        expect(find.textContaining('لم يتم التحقق'), findsNothing);
        expect(find.text('استخدام البصمة'), findsOneWidget);

        await tester.tap(find.text('استخدام البصمة'));
        await _settle(tester);
        expect(biometrics.prompts, 2);
        expect(find.textContaining('لم يتم التحقق بالبصمة'), findsOneWidget);
        await dispose(tester, app);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    testWidgets(
      'no fingerprint button or prompt when biometrics are off',
      (tester) async {
        phoneSized(tester);
        final biometrics = _Biometrics(available: true);
        final app = await createApp(tester, biometrics, initialized: true);

        await tester.pumpWidget(
          JibiApp(application: app, initialView: JibiInitialView.shell),
        );
        await _settle(tester);
        await _settle(tester);

        expect(biometrics.prompts, 0);
        expect(find.text('جيبي مقفل'), findsOneWidget);
        expect(find.text('استخدام البصمة'), findsNothing);
        await dispose(tester, app);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
