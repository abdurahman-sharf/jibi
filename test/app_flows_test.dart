import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:jibi/app/jibi_app.dart';
import 'package:jibi/app/jibi_application.dart';
import 'package:jibi/core/security/security.dart';
import 'package:jibi/core/errors/app_exception.dart';
import 'package:jibi/shared/widgets/amount_input.dart';
import 'support/memory_keys.dart';
import 'support/test_currencies.dart';

void main() {
  test(
    'Arabic money input retains precision and oversized amounts fail safely',
    () {
      final currencies = testCurrencyRegistry();
      expect(
        currencies
            .parseAmount(
              input: normalizeAmountInput(' ١٢٣٫٤٥ '),
              currencyCode: 'SAR',
            )
            .amountMinor,
        12345,
      );
      expect(
        currencies
            .parseAmount(
              input: normalizeAmountInput('۱۲٫۳۴۵'),
              currencyCode: 'KWD',
            )
            .amountMinor,
        12345,
      );
      expect(
        () => currencies.parseAmount(
          input: '999999999999999999999999999',
          currencyCode: 'SAR',
        ),
        throwsA(isA<ValidationException>()),
      );
    },
  );

  testWidgets(
    'production shell routes, saves accounts and masks pushed routes when locked',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfiNoIsolate;
      late Directory directory;
      late JibiApplication app;
      void expectCleanLayout(String stage) {
        expect(tester.takeException(), isNull, reason: stage);
      }

      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('jibi-ui-');
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
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await tester.pumpAndSettle();
      });
      expectCleanLayout('initial lock screen');
      expect(find.text('جيبي مقفل'), findsOneWidget);
      await tester.runAsync(() => app.security.unlockWithPin('123456'));
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await tester.pumpAndSettle();
      });
      expectCleanLayout('home dashboard');
      await tester.tap(find.byTooltip('الإعدادات'));
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await tester.pumpAndSettle();
      });
      expectCleanLayout('settings page');
      expect(find.text('بيانات المستخدم'), findsOneWidget);
      final settingsContext = tester.element(find.text('بيانات المستخدم'));
      expect(Directionality.of(settingsContext), TextDirection.rtl);
      final externalActivity = Completer<void>();
      final guardedActivity = app.runExternalActivity(
        () => externalActivity.future,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expectCleanLayout('settings after an external activity');
      expect(find.text('بيانات المستخدم'), findsOneWidget);
      expect(find.text('جيبي مقفل'), findsNothing);
      externalActivity.complete();
      await guardedActivity;
      await tester.runAsync(() => app.security.lock());
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await tester.pumpAndSettle();
      });
      expectCleanLayout('lock overlay above settings');
      expect(find.text('جيبي مقفل'), findsOneWidget);
      expect(find.text('بيانات المستخدم'), findsNothing);
      await tester.runAsync(() => app.security.unlockWithPin('123456'));
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await tester.pumpAndSettle();
      });
      expectCleanLayout('restored settings route');
      Navigator.of(tester.element(find.text('بيانات المستخدم'))).pop();
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await tester.pumpAndSettle();
      });
      Future<void> settle() => tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await tester.pumpAndSettle();
      });
      Future<void> tapAndSave(Finder finder) => tester.runAsync(() async {
        await tester.tap(finder);
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });

      // Entering the accounts section switches to its own bottom bar.
      expect(find.text('كلمات المرور'), findsWidgets);
      await tester.tap(find.text('الحسابات').last);
      await settle();
      expectCleanLayout('accounts root');
      expect(find.text('لا توجد تصنيفات حتى الآن'), findsOneWidget);
      expect(find.text('التقارير'), findsOneWidget);
      expect(find.text('الإعدادات'), findsOneWidget);
      expect(find.text('كلمات المرور'), findsNothing);
      expect(find.text('المستندات'), findsNothing);

      // The quick-add "+" of this section creates categories, accounts and
      // transactions.
      await tester.tap(find.byType(FloatingActionButton));
      await settle();
      expectCleanLayout('accounts quick-add sheet');
      expect(find.text('عملية جديدة'), findsOneWidget);
      expect(find.text('حساب جديد'), findsOneWidget);
      await tester.tap(find.text('تصنيف جديد'));
      await settle();
      expectCleanLayout('category form');
      // Forms open full-screen: no bar and no second "+" behind them.
      expect(find.byType(BottomAppBar), findsNothing);
      await tester.enterText(find.byKey(const Key('category-name')), 'حسابات اليمن');
      await tapAndSave(find.byKey(const Key('save-button')));
      await settle();
      expectCleanLayout('saved category');
      expect(find.text('حسابات اليمن'), findsOneWidget);

      // Open the category: the bar and the "+" stay on the pushed page.
      await tester.tap(find.text('حسابات اليمن'));
      await settle();
      expectCleanLayout('category page');
      expect(find.text('لا توجد حسابات في هذا التصنيف'), findsOneWidget);
      expect(find.byType(BottomAppBar), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsOneWidget);

      await tester.tap(find.byKey(const Key('add-account-button')));
      await settle();
      expectCleanLayout('account form');
      expect(find.byType(BottomAppBar), findsNothing);
      await tester.enterText(find.byKey(const Key('account-name')), 'حساب اختبار');
      await tapAndSave(find.byKey(const Key('save-button')));
      await settle();
      expectCleanLayout('saved account list');
      final accounts = await tester.runAsync(
        () => app.book.repository.accountSummaries(),
      );
      expect(accounts!.single.account.name, 'حساب اختبار');
      // An account is a person or entity: it has no currency until a
      // transaction (or an opening balance) gives it one.
      expect(accounts.single.currencies, isEmpty);
      final accountId = accounts.single.account.id;

      // The statement opens full-screen with its own totals bar.
      await tester.tap(find.text('حساب اختبار'));
      await settle();
      expectCleanLayout('statement');
      expect(find.byType(BottomAppBar), findsNothing);
      expect(find.text('لا توجد عمليات لهذا الحساب'), findsOneWidget);
      await tester.tap(find.byKey(const Key('statement-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('تعديل الحساب'));
      await settle();
      expect(find.text('حساب اختبار'), findsWidgets);
      await tester.enterText(find.byKey(const Key('account-name')), 'الحساب المعدل');
      await tapAndSave(find.byKey(const Key('save-button')));
      await settle();
      expectCleanLayout('edited account statement');
      expect(find.text('الحساب المعدل'), findsOneWidget);
      final edited = await tester.runAsync(
        () => app.book.repository.account(accountId),
      );
      expect(edited!.name, 'الحساب المعدل');
      expect(edited.createdAt, accounts.single.account.createdAt);
      expect(
        await tester.runAsync(() => app.book.repository.countBalanceMismatches(accountId)),
        0,
      );

      // Back out of the section: "الرئيسية" restores the normal bar.
      Navigator.of(tester.element(find.text('الحساب المعدل'))).pop();
      await settle();
      await tester.tap(find.text('الرئيسية').last);
      await settle();
      expectCleanLayout('home again');
      expect(find.text('كلمات المرور'), findsWidgets);
      expect(find.text('التقارير'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await app.dispose();
        await directory.delete(recursive: true);
      });
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
