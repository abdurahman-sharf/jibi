import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/app/book/book_categories_page.dart';
import 'package:jibi/app/book/book_category_management_page.dart';
import 'package:jibi/app/book/book_category_page.dart';
import 'package:jibi/core/models/models.dart';
import 'package:jibi/features/book/book.dart';

import '../../support/book_harness.dart';
import '../../support/test_currencies.dart';

BookServices _emptyBook() => BookServices(
  repository: InMemoryBookRepository(),
  currencies: testCurrencyRegistry(),
  defaultCurrencyCode: () => 'SAR',
);

void main() {
  group('categories root', () {
    testWidgets('an empty book offers to add the first category', (
      tester,
    ) async {
      final book = _emptyBook();
      addTearDown(book.repository.dispose);
      await pumpBookPage(tester, Scaffold(body: BookCategoriesPage(book: book)));

      expect(find.text('لا توجد تصنيفات حتى الآن'), findsOneWidget);
      await tester.tap(find.text('إضافة تصنيف'));
      await tester.pumpAndSettle();
      expect(find.text('إضافة تصنيف جديد'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('category-name')),
        'حسابات اليمن',
      );
      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();

      expect(find.text('حسابات اليمن'), findsOneWidget);
      expect(find.text('لا توجد تصنيفات حتى الآن'), findsNothing);
    });

    testWidgets('an empty name is rejected with a message', (tester) async {
      final book = _emptyBook();
      addTearDown(book.repository.dispose);
      await pumpBookPage(tester, Scaffold(body: BookCategoriesPage(book: book)));

      await tester.tap(find.text('إضافة تصنيف'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();

      expect(find.text('أدخل اسم التصنيف.'), findsOneWidget);
      expect(await book.repository.categorySummaries(), isEmpty);
    });

    testWidgets('shows the position per currency and the category card', (
      tester,
    ) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      await pumpBookPage(
        tester,
        Scaffold(body: BookCategoriesPage(book: fixture.book)),
      );

      expect(find.text('مدونة الحسابات'), findsOneWidget);
      expect(find.text('حسابات اليمن'), findsOneWidget);
      expect(find.text('4 حساب'), findsOneWidget);
      // The two currencies are shown apart, never added together.
      expect(find.text('YER'), findsWidgets);
      expect(find.text('SAR'), findsWidgets);
      expect(find.text('4,850.00'), findsWidgets);
    });
  });

  group('category page', () {
    testWidgets('lists accounts with counts, filters by balance side', (
      tester,
    ) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      await pumpBookPage(
        tester,
        BookCategoryPage(book: fixture.book, categoryId: fixture.category.id),
        size: const Size(390, 2400),
      );

      expect(find.text('علي أخي'), findsOneWidget);
      expect(find.text('التحويلات الواردة'), findsOneWidget);
      expect(find.text('أسامة أخي'), findsOneWidget);
      expect(find.text('2 عملية مسجلة'), findsOneWidget);
      expect(find.text('الكل (4)'), findsOneWidget);
      expect(find.text('مدين (2)'), findsOneWidget);
      expect(find.text('دائن (1)'), findsOneWidget);
      expect(find.text('متعادل (1)'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('chip-credit')));
      await tester.tap(find.byKey(const Key('chip-credit')));
      await tester.pumpAndSettle();
      expect(find.text('التحويلات الواردة'), findsOneWidget);
      expect(find.text('علي أخي'), findsNothing);

      await tester.ensureVisible(find.byKey(const Key('chip-settled')));
      await tester.tap(find.byKey(const Key('chip-settled')));
      await tester.pumpAndSettle();
      expect(find.text('أسامة أخي'), findsOneWidget);
      expect(find.text('التحويلات الواردة'), findsNothing);
    });

    testWidgets('the summary is per currency and switchable', (tester) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      await pumpBookPage(
        tester,
        BookCategoryPage(book: fixture.book, categoryId: fixture.category.id),
        size: const Size(390, 2400),
      );

      final summary = find.byKey(const Key('category-summary'));
      // YER has the most accounts, so it is the default currency.
      expect(
        find.descendant(of: summary, matching: find.text('30,100')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: summary, matching: find.text('302,500')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: summary, matching: find.text('272,400')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('currency-SAR')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: summary, matching: find.text('4,850.00')),
        findsWidgets,
      );
      expect(
        find.descendant(of: summary, matching: find.text('30,100')),
        findsNothing,
      );
    });

    testWidgets('search narrows the accounts by name', (tester) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      await pumpBookPage(
        tester,
        BookCategoryPage(book: fixture.book, categoryId: fixture.category.id),
        size: const Size(390, 2400),
      );

      await tester.tap(find.byKey(const Key('category-search')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('account-search')), 'أسامة');
      await tester.pumpAndSettle();
      expect(find.text('أسامة أخي'), findsOneWidget);
      expect(find.text('علي أخي'), findsNothing);

      await tester.enterText(find.byKey(const Key('account-search')), 'zzz');
      await tester.pumpAndSettle();
      expect(find.text('لا توجد حسابات مطابقة.'), findsOneWidget);
    });

    testWidgets('an empty category shows the empty state', (tester) async {
      final fixture = await BookFixture.create(seed: false);
      addTearDown(fixture.dispose);
      await pumpBookPage(
        tester,
        BookCategoryPage(book: fixture.book, categoryId: fixture.category.id),
        size: const Size(390, 2400),
      );
      expect(find.text('لا توجد حسابات في هذا التصنيف'), findsOneWidget);
      expect(find.text('إضافة حساب'), findsOneWidget);
    });

    testWidgets('a new account is created with a credit opening balance', (
      tester,
    ) async {
      final fixture = await BookFixture.create(seed: false);
      addTearDown(fixture.dispose);
      await pumpBookPage(
        tester,
        BookCategoryPage(book: fixture.book, categoryId: fixture.category.id),
        size: const Size(390, 2400),
      );

      await tester.tap(find.byKey(const Key('add-account-button')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('account-name')), 'أبي');
      await tester.enterText(
        find.byKey(const Key('account-phone')),
        '0530882752',
      );
      // An account has no currency of its own: an opening balance is added,
      // optionally, per currency — the base currency is preselected.
      await tester.dragUntilVisible(
        find.byKey(const Key('add-opening')),
        find.byType(ListView),
        const Offset(0, -300),
      );
      await tester.tap(find.byKey(const Key('add-opening')));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byKey(const Key('opening-type-0')),
        matching: find.text('دائن'),
      ));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('opening-amount-0')), '150000');
      await tester.pump();
      // The amount is grouped while typing.
      expect(find.text('150,000'), findsOneWidget);
      await tester.dragUntilVisible(
        find.byKey(const Key('save-button')),
        find.byType(ListView),
        const Offset(0, -300),
      );
      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();

      final accounts = await fixture.book.repository.accountSummaries();
      expect(accounts.single.account.name, 'أبي');
      // The form preselects the user's base currency (the test harness's is
      // SAR); the opening balance belongs to that currency alone.
      final opening = (await fixture.book.repository.accountBalancesOf(
        accounts.single.account.id,
      )).single;
      expect(opening.currencyCode, 'SAR');
      expect(opening.openingType, OpeningType.credit);
      // SAR has 2 fraction digits (unlike the old hardcoded YER, which had
      // none), so the typed whole number "150000" parses to 150,000.00 SAR.
      expect(accounts.single.totalsOf('SAR')!.creditMinor, 15000000);
      expect(accounts.single.currencyCodes, ['SAR']);
      expect(accounts.single.account.phone, '0530882752');
      expect(find.text('أبي'), findsOneWidget);
    });

    testWidgets('an archived account is hidden until asked for', (
      tester,
    ) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      await fixture.book.accounts.setStatus(
        fixture.osama.id,
        BookAccountStatus.archived,
      );
      await pumpBookPage(
        tester,
        BookCategoryPage(book: fixture.book, categoryId: fixture.category.id),
        size: const Size(390, 2400),
      );
      expect(find.text('أسامة أخي'), findsNothing);
      await tester.ensureVisible(find.byKey(const Key('chip-archived')));
      await tester.tap(find.byKey(const Key('chip-archived')));
      await tester.pumpAndSettle();
      expect(find.text('أسامة أخي'), findsOneWidget);
    });
  });

  group('category management', () {
    testWidgets('switching a category off hides it from the root', (
      tester,
    ) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      await pumpBookPage(
        tester,
        Scaffold(body: BookCategoriesPage(book: fixture.book)),
      );
      expect(find.text('حسابات اليمن'), findsOneWidget);

      await fixture.book.categories.setActive(
        fixture.category.id,
        isActive: false,
      );
      await tester.pumpAndSettle();
      expect(find.text('حسابات اليمن'), findsNothing);
      expect(find.text('لا توجد تصنيفات حتى الآن'), findsOneWidget);
    });

    testWidgets('the switch, archive and delete rules work', (tester) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      final empty = await fixture.book.categories.create(
        const BookCategoryDraft(name: 'فارغ'),
      );
      await pumpBookPage(
        tester,
        BookCategoryManagementPage(book: fixture.book),
      );
      expect(find.text('حسابات اليمن'), findsOneWidget);
      expect(find.text('فارغ'), findsOneWidget);

      // Off: dimmed with the "kept in the database" note, data intact.
      await tester.tap(find.byKey(Key('switch-${fixture.category.id}')));
      await tester.pumpAndSettle();
      expect(find.textContaining('محفوظ بالكامل'), findsOneWidget);
      expect(
        (await fixture.book.repository.category(fixture.category.id))!.isActive,
        isFalse,
      );
      expect(
        await fixture.book.repository.accountCount(fixture.category.id),
        4,
      );

      // A category with accounts can be deleted too: everything inside
      // cascades (its accounts and their transactions).
      await tester.tap(find.byKey(Key('category-menu-${fixture.category.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('حذف'));
      await tester.pumpAndSettle();
      expect(find.textContaining('حسابات اليمن'), findsWidgets);
      await tester.tap(find.widgetWithText(FilledButton, 'حذف'));
      await tester.pumpAndSettle();
      expect(find.text('حسابات اليمن'), findsNothing);
      expect(
        await fixture.book.repository.category(fixture.category.id),
        isNull,
      );
      expect(
        await fixture.book.repository.accountCount(fixture.category.id),
        0,
      );

      // An empty one can be deleted after confirming.
      await tester.tap(find.byKey(Key('category-menu-${empty.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('حذف'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'حذف'));
      await tester.pumpAndSettle();
      expect(find.text('فارغ'), findsNothing);
    });
  });
}
