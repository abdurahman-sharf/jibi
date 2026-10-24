import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/app/currency_management_page.dart';
import 'package:jibi/app/jibi_application.dart';
import 'package:jibi/core/models/currency_palette.dart';
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

void main() {
  late Directory directory;
  late JibiApplication app;

  setUp(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  Future<void> openPage(
    WidgetTester tester, {
    Size size = const Size(390, 2600),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('jibi-currencies-');
      final security = AesGcmSecurityService(
        keyStore: MemoryKeys(),
        biometricAuthenticator: NoBiometrics(),
      );
      await security.initialize(pin: '123456');
      app = await JibiApplication.create(
        directory: directory,
        securityService: security,
      );
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await app.dispose();
        await directory.delete(recursive: true);
      });
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: JibiTheme.light(),
        locale: const Locale('ar'),
        supportedLocales: const [Locale('ar')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: CurrencyManagementPage(application: app),
      ),
    );
    await _settle(tester);
  }

  /// Taps something that ends in real database work, then lets it finish.
  Future<void> tapAndWait(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(finder);
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await _settle(tester);
  }

  Future<void> menu(WidgetTester tester, String code, String item) async {
    await tapAndWait(tester, find.byKey(Key('currency-menu-$code')));
    await tapAndWait(tester, find.text(item));
  }

  double top(WidgetTester tester, String code) =>
      tester.getTopLeft(find.byKey(Key('currency-card-$code'))).dy;

  /// A book account in USD, which is what makes the currency "in use".
  Future<void> createUsdAccount(WidgetTester tester) async {
    await tester.runAsync(() async {
      final category = await app.book.categories.create(
        const BookCategoryDraft(name: 'أشخاص'),
      );
      await app.book.accounts.create(
        BookAccountDraft.single(
          categoryId: category.id,
          name: 'أحمد',
          currencyCode: 'USD',
        ),
      );
    });
  }

  testWidgets('shows a card per currency and a styled add button', (
    tester,
  ) async {
    await openPage(tester);

    for (final code in ['SAR', 'USD', 'YER']) {
      expect(find.byKey(Key('currency-card-$code')), findsOneWidget);
    }
    // The base currency is marked once; nothing starts out disabled.
    expect(find.text('الأساسية'), findsOneWidget);
    expect(find.text('معطّلة'), findsNothing);
    expect(find.textContaining('العملة الأساسية:'), findsOneWidget);

    // The add button is a real filled button, fixed at the bottom, not the
    // theme's round floating button squeezed around a label.
    expect(find.byType(FloatingActionButton), findsNothing);
    final add = find.byKey(const Key('add-currency-button'));
    expect(add, findsOneWidget);
    expect(
      find.descendant(of: add, matching: find.text('إضافة عملة')),
      findsOneWidget,
    );
    final box = tester.getRect(add);
    expect(box.height, greaterThanOrEqualTo(48));
    expect(box.width, greaterThan(250));
    expect(box.bottom, greaterThan(2400));
    expect(tester.takeException(), isNull);
  });

  testWidgets('adds a currency from the form and validates it first', (
    tester,
  ) async {
    await openPage(tester);
    await tapAndWait(tester, find.byKey(const Key('add-currency-button')));

    // Nothing entered: the name is asked for.
    await tester.tap(find.byKey(const Key('currency-save-button')));
    await tester.pump();
    expect(find.text('أدخل اسم العملة.'), findsOneWidget);

    // Only letters can be typed into the code, and it needs three.
    await tester.enterText(
      find.byKey(const Key('currency-name-field')),
      'جنيه',
    );
    await tester.enterText(find.byKey(const Key('currency-code-field')), 'e1g');
    await tester.tap(find.byKey(const Key('currency-save-button')));
    await tester.pump();
    expect(find.textContaining('ثلاثة أحرف إنجليزية.'), findsWidgets);
    expect(find.byKey(const Key('currency-card-EG')), findsNothing);

    await tester.enterText(find.byKey(const Key('currency-code-field')), 'egp');
    await tester.enterText(
      find.byKey(const Key('currency-name-field')),
      'جنيه مصري',
    );
    await tester.enterText(
      find.byKey(const Key('currency-symbol-field')),
      'ج.م',
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('currency-digits-field')),
        matching: find.text('3'),
      ),
    );
    await tester.pump();
    await tapAndWait(tester, find.byKey(const Key('currency-save-button')));

    expect(find.byKey(const Key('currency-card-EGP')), findsOneWidget);
    expect(find.text('جنيه مصري'), findsOneWidget);
    expect(find.text('3 منازل عشرية'), findsWidgets);
    expect(app.currencyRegistry.byCode('EGP').fractionDigits, 3);
    // Left on "automatic", it still gets the first palette color no currency
    // wears yet (the shipped three use the first three).
    expect(app.currencyRegistry.byCode('EGP').colorValue, currencyPalette[3]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a currency can be given a color that survives a reload', (
    tester,
  ) async {
    await openPage(tester);
    const picked = 0xFF7B4FB8;
    expect(app.currencyRegistry.byCode('SAR').colorValue, sarCurrencyColor);

    await menu(tester, 'SAR', 'تعديل');
    await tester.ensureVisible(
      find.byKey(const Key('currency-color-FF7B4FB8')),
    );
    await tester.tap(find.byKey(const Key('currency-color-FF7B4FB8')));
    await tester.pump();
    await tapAndWait(tester, find.byKey(const Key('currency-save-button')));

    expect(app.currencyRegistry.byCode('SAR').colorValue, picked);
    final stored = await tester.runAsync(
      () => app.repository.findCurrency('SAR'),
    );
    expect(stored!.colorValue, picked);
    expect(tester.takeException(), isNull);

    // "Automatic" clears it again.
    await menu(tester, 'SAR', 'تعديل');
    await tester.ensureVisible(find.byKey(const Key('currency-color-auto')));
    await tester.tap(find.byKey(const Key('currency-color-auto')));
    await tester.pump();
    await tapAndWait(tester, find.byKey(const Key('currency-save-button')));
    expect(app.currencyRegistry.byCode('SAR').colorValue, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('turns a currency off and refuses to turn the base one off', (
    tester,
  ) async {
    await openPage(tester);

    await tapAndWait(tester, find.byKey(const Key('currency-switch-USD')));
    expect(find.text('معطّلة'), findsOneWidget);
    expect(app.currencyRegistry.byCode('USD').isActive, isFalse);

    await tapAndWait(tester, find.byKey(const Key('currency-switch-YER')));
    expect(find.textContaining('اختر عملة افتراضية بديلة'), findsOneWidget);
    expect(app.currencyRegistry.byCode('YER').isActive, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('makes another currency the base one', (tester) async {
    await openPage(tester);
    // The Yemeni rial is the base a fresh install starts with.
    expect(app.settings.defaultCurrencyCode, 'YER');

    await menu(tester, 'USD', 'جعلها العملة الأساسية');

    expect(app.settings.defaultCurrencyCode, 'USD');
    expect(find.text('الأساسية'), findsOneWidget);
    // The badge moved with it: only the new base has no "make default" item.
    await tapAndWait(tester, find.byKey(const Key('currency-menu-USD')));
    expect(find.text('جعلها العملة الأساسية'), findsNothing);
    expect(find.text('حذف'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('moves a currency down and up', (tester) async {
    await openPage(tester);
    expect(top(tester, 'SAR'), lessThan(top(tester, 'USD')));

    await menu(tester, 'SAR', 'نقل للأسفل');
    expect(top(tester, 'SAR'), greaterThan(top(tester, 'USD')));

    await menu(tester, 'SAR', 'نقل للأعلى');
    expect(top(tester, 'SAR'), lessThan(top(tester, 'USD')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('deletes an unused currency after confirming, never a used one', (
    tester,
  ) async {
    await openPage(tester);
    await createUsdAccount(tester);

    // Declining the confirmation keeps it.
    await menu(tester, 'SAR', 'حذف');
    expect(find.text('حذف العملة'), findsOneWidget);
    await tapAndWait(tester, find.text('إلغاء'));
    expect(find.byKey(const Key('currency-card-SAR')), findsOneWidget);

    await menu(tester, 'SAR', 'حذف');
    await tapAndWait(tester, find.widgetWithText(FilledButton, 'حذف'));
    expect(find.byKey(const Key('currency-card-SAR')), findsNothing);

    // A currency an account already uses is refused, with the reason.
    await menu(tester, 'USD', 'حذف');
    await tapAndWait(tester, find.widgetWithText(FilledButton, 'حذف'));
    expect(find.byKey(const Key('currency-card-USD')), findsOneWidget);
    expect(find.textContaining('لا يمكن حذف عملة مستخدمة'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editing keeps the code fixed and locks used decimals', (
    tester,
  ) async {
    await openPage(tester);
    await createUsdAccount(tester);

    await menu(tester, 'USD', 'تعديل');
    expect(find.byKey(const Key('currency-code-field')), findsNothing);
    await tester.enterText(
      find.byKey(const Key('currency-name-field')),
      'دولار',
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('currency-digits-field')),
        matching: find.text('3'),
      ),
    );
    await tester.pump();
    await tapAndWait(tester, find.byKey(const Key('currency-save-button')));

    // The decimals of a used currency cannot change, so the edit is refused
    // (the shipped dollar has none).
    expect(find.textContaining('بعد استخدام العملة'), findsOneWidget);
    expect(app.currencyRegistry.byCode('USD').fractionDigits, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fits a narrow phone with large text without overflowing', (
    tester,
  ) async {
    await openPage(tester, size: const Size(320, 900), textScale: 1.6);

    expect(find.byKey(const Key('add-currency-button')), findsOneWidget);
    expect(find.byKey(const Key('currency-card-YER')), findsOneWidget);
    expect(find.byKey(const Key('currency-menu-YER')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tapAndWait(tester, find.byKey(const Key('add-currency-button')));
    expect(find.byKey(const Key('currency-digits-field')), findsOneWidget);
    expect(find.byKey(const Key('currency-color-auto')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
