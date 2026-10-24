import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/app/coach_tours.dart';
import 'package:jibi/app/jibi_app.dart';
import 'package:jibi/app/jibi_application.dart';
import 'package:jibi/app/settings/general_settings_page.dart';
import 'package:jibi/core/security/security.dart';
import 'package:jibi/features/book/book.dart';
import 'package:jibi/shared/theme/jibi_theme.dart';

import '../support/memory_keys.dart' show MemoryKeys, NoBiometrics;

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
  });
}

/// Waits (real time and frames) until a hint tour opens, or a while longer if
/// none is expected. The host's wait is a real timer created while the test
/// runs real async work, so both clocks have to move. The overlay's ring pulses
/// forever, so this never uses pumpAndSettle.
Future<void> _waitForHints(WidgetTester tester, {bool expected = true}) async {
  for (var round = 0; round < (expected ? 80 : 6); round++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    if (expected && find.byKey(const Key('coach-overlay')).evaluate().isNotEmpty) {
      await tester.pump(const Duration(milliseconds: 400));
      return;
    }
  }
}

void main() {
  late Directory directory;
  late JibiApplication app;

  setUp(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  Future<void> createApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.jibi.jibi/screen_protection'),
      (_) async => null,
    );
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('jibi-tips-');
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

  Future<void> tearDownApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await app.dispose();
      await directory.delete(recursive: true);
    });
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.jibi.jibi/screen_protection'),
      null,
    );
  }

  Future<void> openApp(WidgetTester tester, {bool showTips = true}) async {
    await tester.pumpWidget(
      JibiApp(
        application: app,
        initialView: JibiInitialView.shell,
        showTips: showTips,
        // Real timers run inside runAsync: a wait of zero keeps them short.
        tipsDelay: Duration.zero,
      ),
    );
    await _settle(tester);
    expect(find.text('جيبي مقفل'), findsOneWidget);
    await tester.runAsync(() => app.security.unlockWithPin('123456'));
    await _settle(tester);
  }

  /// Lets the settings write that follows a finished tour complete (it is real
  /// database work).
  Future<void> saved(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Taps "التالي" until the last hint, then confirms it.
  Future<int> finishTour(WidgetTester tester) async {
    var steps = 0;
    while (find.byKey(const Key('coach-overlay')).evaluate().isNotEmpty &&
        steps < 20) {
      steps++;
      await tester.tap(find.byKey(const Key('coach-next')));
      await tester.pump(const Duration(milliseconds: 400));
    }
    await saved(tester);
    return steps;
  }

  group('the home tour', () {
    testWidgets('appears after the first unlock and is remembered', (
      tester,
    ) async {
      await createApp(tester);
      await openApp(tester);
      await _waitForHints(tester);

      expect(find.byKey(const Key('coach-overlay')), findsOneWidget);
      expect(find.text('البحث الشامل'), findsOneWidget);
      expect(app.settings.seenTours, isEmpty);

      final steps = await finishTour(tester);

      expect(steps, greaterThanOrEqualTo(5));
      expect(find.byKey(const Key('coach-overlay')), findsNothing);
      expect(app.settings.seenTours, contains(CoachTourIds.home));

      // Locking and unlocking again does not repeat it.
      await tester.runAsync(() => app.security.lock());
      await _settle(tester);
      await tester.runAsync(() => app.security.unlockWithPin('123456'));
      await _settle(tester);
      await _waitForHints(tester, expected: false);
      expect(find.byKey(const Key('coach-overlay')), findsNothing);
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 3)));

    testWidgets('points at the buttons of the top bar and the bottom bar', (
      tester,
    ) async {
      await createApp(tester);
      await openApp(tester);
      await _waitForHints(tester);

      final seen = <String>[];
      for (var guard = 0; guard < 20; guard++) {
        final texts = find
            .descendant(
              of: find.byKey(const Key('coach-overlay')),
              matching: find.byType(Text),
            )
            .evaluate()
            .map((element) => (element.widget as Text).data ?? '')
            .toList();
        seen.addAll(texts);
        final last = find.text('فهمت');
        if (last.evaluate().isNotEmpty) break;
        await tester.tap(find.byKey(const Key('coach-next')));
        await tester.pump(const Duration(milliseconds: 400));
      }

      for (final expected in [
        'البحث الشامل',
        'الإعدادات',
        'زر الإضافة',
        'الحسابات',
      ]) {
        expect(seen, contains(expected), reason: expected);
      }
      await tester.tap(find.byKey(const Key('coach-next')));
      await saved(tester);
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 3)));

    testWidgets('is off in an app that does not run tips', (tester) async {
      await createApp(tester);
      await openApp(tester, showTips: false);
      await _waitForHints(tester, expected: false);

      expect(find.byKey(const Key('coach-overlay')), findsNothing);
      expect(app.settings.seenTours, isEmpty);
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 3)));

    testWidgets('stays away when the hints are switched off', (tester) async {
      await createApp(tester);
      await tester.runAsync(
        () => app.saveSettings(app.settings.copyWith(showCoachMarks: false)),
      );
      await openApp(tester);
      await _waitForHints(tester, expected: false);

      expect(find.byKey(const Key('coach-overlay')), findsNothing);
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 3)));

    testWidgets('does not cover the lock screen', (tester) async {
      await createApp(tester);
      await tester.pumpWidget(
        JibiApp(
          application: app,
          initialView: JibiInitialView.shell,
          showTips: true,
          tipsDelay: Duration.zero,
        ),
      );
      await _settle(tester);
      await _waitForHints(tester, expected: false);

      expect(find.text('جيبي مقفل'), findsOneWidget);
      expect(find.byKey(const Key('coach-overlay')), findsNothing);
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('the accounts tours', () {
    Future<void> seedBook(WidgetTester tester) => tester.runAsync(() async {
      final category = await app.book.categories.create(
        const BookCategoryDraft(name: 'حسابات اليمن'),
      );
      await app.book.accounts.create(
        BookAccountDraft.single(
          categoryId: category.id,
          name: 'علي أخي',
          currencyCode: 'YER',
        ),
      );
    });

    testWidgets('the accounts tab gets its own tour on the first visit', (
      tester,
    ) async {
      await createApp(tester);
      await seedBook(tester);
      await tester.runAsync(
        () => app.saveSettings(app.settings.withSeenTour(CoachTourIds.home)),
      );
      await openApp(tester);
      await _waitForHints(tester, expected: false);
      // Still on the home tab: nothing to show yet.
      expect(find.byKey(const Key('coach-overlay')), findsNothing);

      await tester.tap(find.text('الحسابات').last);
      // The tour opens while the tab settles, so no pumpAndSettle here.
      await _waitForHints(tester);

      expect(find.byKey(const Key('coach-overlay')), findsOneWidget);
      expect(find.text('الصافي لكل عملة'), findsOneWidget);
      await tester.tap(find.byKey(const Key('coach-skip')));
      await tester.pump(const Duration(milliseconds: 400));
      await saved(tester);
      expect(app.settings.seenTours, contains(CoachTourIds.accounts));
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 3)));

    testWidgets('the statement gets its tour when an account is opened', (
      tester,
    ) async {
      await createApp(tester);
      await seedBook(tester);
      await tester.runAsync(
        () => app.saveSettings(
          app.settings
              .withSeenTour(CoachTourIds.home)
              .withSeenTour(CoachTourIds.accounts),
        ),
      );
      await openApp(tester);
      await tester.tap(find.text('الحسابات').last);
      await _settle(tester);
      await tester.tap(find.text('حسابات اليمن'));
      await _settle(tester);
      await tester.tap(find.text('علي أخي'));
      await _settle(tester);
      await _waitForHints(tester);

      expect(find.byKey(const Key('coach-overlay')), findsOneWidget);
      expect(find.text('تقارير الحساب'), findsOneWidget);
      await tester.tap(find.byKey(const Key('coach-skip')));
      await tester.pump(const Duration(milliseconds: 400));
      await saved(tester);
      expect(app.settings.seenTours, contains(CoachTourIds.account));
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('the settings of the hints', () {
    Future<void> openGeneral(WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 2400);
      await tester.pumpWidget(
        MaterialApp(
          theme: JibiTheme.light(),
          locale: const Locale('ar'),
          supportedLocales: const [Locale('ar')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: Material(child: GeneralSettingsPage(application: app)),
          ),
        ),
      );
      await _settle(tester);
    }

    Future<void> tapAndWait(WidgetTester tester, Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(finder);
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await _settle(tester);
    }

    testWidgets('the switch turns the hints off and on', (tester) async {
      await createApp(tester);
      await openGeneral(tester);
      expect(app.settings.showCoachMarks, isTrue);

      await tapAndWait(tester, find.byKey(const Key('general-tips')));
      expect(app.settings.showCoachMarks, isFalse);
      await tapAndWait(tester, find.byKey(const Key('general-tips')));
      expect(app.settings.showCoachMarks, isTrue);
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 2)));

    testWidgets('showing the hints again forgets which were seen', (
      tester,
    ) async {
      await createApp(tester);
      await tester.runAsync(
        () => app.saveSettings(
          app.settings
              .withSeenTour(CoachTourIds.home)
              .withSeenTour(CoachTourIds.account)
              .copyWith(showCoachMarks: false),
        ),
      );
      await openGeneral(tester);

      await tapAndWait(tester, find.byKey(const Key('general-replay-tips')));

      expect(app.settings.seenTours, isEmpty);
      expect(app.settings.showCoachMarks, isTrue);
      expect(find.textContaining('ستظهر التلميحات من جديد'), findsOneWidget);
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 2)));

    testWidgets('the tour of the features can be replayed', (tester) async {
      await createApp(tester);
      await openGeneral(tester);

      await tapAndWait(tester, find.byKey(const Key('general-replay-tour')));
      expect(find.byKey(const Key('walkthrough')), findsOneWidget);

      await tester.tap(find.byKey(const Key('walkthrough-skip')));
      await _settle(tester);
      expect(find.byKey(const Key('walkthrough')), findsNothing);
      expect(find.byKey(const Key('general-settings')), findsOneWidget);
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
