import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/app/jibi_app.dart';
import 'package:jibi/app/jibi_application.dart';
import 'package:jibi/core/security/security.dart';
import 'package:jibi/features/book/book.dart';

import '../support/memory_keys.dart' show MemoryKeys, NoBiometrics;

/// The general expenses feature is gone (schema v9): no screen, button, card,
/// activity row or search section leads to it, and the home tile that used to
/// add an expense now adds an account.
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
  });
}

void main() {
  testWidgets(
    'no way to add or see expenses is left, and the home tile adds an account',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfiNoIsolate;
      late Directory directory;
      late JibiApplication app;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('jibi-no-expenses-');
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
        // A category, so the account form opens instead of the category form.
        await app.book.categories.create(
          const BookCategoryDraft(name: 'الأشخاص'),
        );
      });
      await tester.pumpWidget(
        JibiApp(application: app, initialView: JibiInitialView.shell),
      );
      await _settle(tester);
      await tester.runAsync(() => app.security.unlockWithPin('123456'));
      await _settle(tester);

      // Home: the expense tile and the monthly-expenses card are gone.
      expect(find.text('مرحباً بك في جيبي 👋'), findsOneWidget);
      expect(find.text('إضافة مصروف'), findsNothing);
      expect(find.text('مصاريف هذا الشهر'), findsNothing);
      expect(find.text('إضافة كلمة مرور'), findsOneWidget);
      expect(find.text('إضافة مستند'), findsOneWidget);
      expect(find.text('حساب جديد'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // The "+" sheet no longer offers an expense.
      await tester.tap(find.byIcon(Icons.add));
      await _settle(tester);
      expect(find.text('أضف مصروفًا جديدًا'), findsNothing);
      expect(find.text('مصروف'), findsNothing);
      expect(find.text('أضف حسابًا داخل أحد التصنيفات'), findsOneWidget);
      await tester.tapAt(const Offset(195, 20));
      await _settle(tester);

      // Search has no expenses section.
      await tester.tap(find.byTooltip('بحث'));
      await _settle(tester);
      expect(find.text('المصاريف'), findsNothing);
      expect(find.text('الحسابات'), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'ابحث في الحسابات والخدمات والمستندات'),
        findsOneWidget,
      );
      await tester.tap(find.byType(BackButton));
      await _settle(tester);

      // Accounts: no link to a general expenses list.
      await tester.tap(find.text('الحسابات').last);
      await _settle(tester);
      expect(find.text('المصروفات العامة'), findsNothing);
      expect(find.byKey(const Key('expenses-link')), findsNothing);
      await tester.tap(find.text('الرئيسية').last);
      await _settle(tester);

      // The replacement tile opens the account form.
      await tester.tap(find.text('حساب جديد'));
      await _settle(tester);
      expect(find.text('إضافة حساب جديد'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await app.dispose();
        try {
          await directory.delete(recursive: true);
        } on FileSystemException {
          // Windows keeps SQLite handles briefly after close; the test is done.
        }
      });
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
