import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/app/book/book_archive_page.dart';
import 'package:jibi/app/book/book_audit_page.dart';
import 'package:jibi/core/models/models.dart';
import 'package:jibi/features/book/book.dart';

import '../../support/book_harness.dart';
import '../../support/test_currencies.dart';

void main() {
  late BookFixture fixture;

  setUp(() async {
    fixture = await BookFixture.create();
  });

  tearDown(() => fixture.dispose());

  group('the audit log screen', () {
    // A tall screen, so the whole (lazily built) list is on it.
    Future<void> open(WidgetTester tester, {String? accountId}) => pumpBookPage(
      tester,
      BookAuditLogPage(book: fixture.book, accountId: accountId),
      size: const Size(390, 2400),
    );

    testWidgets('tells what happened, newest first, under today', (tester) async {
      await open(tester);

      expect(find.text('سجل التعديلات'), findsOneWidget);
      expect(find.text('اليوم'), findsOneWidget);
      expect(find.text('تم إنشاء العملية TX-000001'), findsOneWidget);
      expect(find.text('مدين 30,000 YER'), findsOneWidget);
      expect(find.text('دائن 302,500 YER'), findsOneWidget);
      expect(find.text('تم إنشاء الحساب علي أخي'), findsOneWidget);
      expect(find.text('تم إنشاء التصنيف حسابات اليمن'), findsOneWidget);
      // The newest transaction (TX-000004) is above the oldest one.
      final newest = tester.getTopLeft(find.text('تم إنشاء العملية TX-000004')).dy;
      final oldest = tester.getTopLeft(find.text('تم إنشاء العملية TX-000001')).dy;
      expect(newest, lessThan(oldest));
      expect(tester.takeException(), isNull);
    });

    testWidgets('an edit and a delete appear in words', (tester) async {
      final rows = (await fixture.book.repository.transactionPage(
        fixture.ali.id,
        newestFirst: false,
        limit: 10,
      )).items;
      await fixture.book.transactions.update(
        rows.first.id,
        BookTransactionDraft(
          accountId: fixture.ali.id,
          currencyCode: 'YER',
          walletId: fixture.mainWallet.id,
          type: EntryType.debit,
          amountMinor: 20000,
          date: rows.first.date,
          details: rows.first.details,
        ),
      );
      await fixture.book.transactions.delete(rows.last.id);
      await open(tester);

      expect(find.text('تم تعديل مبلغ العملية TX-000001'), findsOneWidget);
      expect(find.text('من 30,000 YER إلى 20,000 YER'), findsOneWidget);
      expect(find.text('تم حذف العملية TX-000002'), findsOneWidget);
    });

    testWidgets('the filters keep one kind of entry', (tester) async {
      await open(tester);

      await tester.tap(find.byKey(const Key('audit-filter-transaction')));
      await tester.pumpAndSettle();
      expect(find.textContaining('تم إنشاء العملية'), findsNWidgets(4));
      expect(find.textContaining('تم إنشاء الحساب'), findsNothing);

      await tester.tap(find.byKey(const Key('audit-filter-account')));
      await tester.pumpAndSettle();
      expect(find.textContaining('تم إنشاء الحساب'), findsNWidgets(4));
      expect(find.textContaining('تم إنشاء العملية'), findsNothing);

      // The chips scroll sideways; the last one may be off screen.
      await tester.ensureVisible(find.byKey(const Key('audit-filter-category')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('audit-filter-category')));
      await tester.pumpAndSettle();
      expect(find.text('تم إنشاء التصنيف حسابات اليمن'), findsOneWidget);
      expect(find.textContaining('تم إنشاء الحساب'), findsNothing);

      await tester.ensureVisible(find.byKey(const Key('audit-filter-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('audit-filter-all')));
      await tester.pumpAndSettle();
      expect(find.textContaining('تم إنشاء العملية'), findsNWidgets(4));
    });

    testWidgets('an account\'s log has only that account and no category filter',
        (tester) async {
      await open(tester, accountId: fixture.ali.id);

      expect(find.text('سجل الحساب'), findsOneWidget);
      expect(find.byKey(const Key('audit-filter-category')), findsNothing);
      // علي أخي has two transactions; the others belong to other accounts.
      expect(find.text('تم إنشاء العملية TX-000001'), findsOneWidget);
      expect(find.text('تم إنشاء العملية TX-000002'), findsOneWidget);
      expect(find.text('تم إنشاء العملية TX-000003'), findsNothing);
      expect(find.text('تم إنشاء الحساب علي أخي'), findsOneWidget);
      expect(find.text('تم إنشاء الحساب أسامة أخي'), findsNothing);
    });

    testWidgets('a new edit shows up while the screen is open', (tester) async {
      await open(tester);
      expect(find.text('تم إنشاء العملية TX-000005'), findsNothing);

      await tester.runAsync(
        () => fixture.book.transactions.create(
          BookTransactionDraft(
            accountId: fixture.osama.id,
            currencyCode: 'YER',
            walletId: fixture.mainWallet.id,
            type: EntryType.debit,
            amountMinor: 500,
            date: '2026-09-20',
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(find.text('تم إنشاء العملية TX-000005'), findsOneWidget);
    });

    testWidgets('opening an entry goes to its account', (tester) async {
      await open(tester);

      await tester.tap(find.text('تم إنشاء العملية TX-000003'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('statement-scroll')), findsOneWidget);
      expect(find.text('التحويلات الواردة'), findsWidgets);
    });

    testWidgets('a log scrolled to the end loads the next pages', (tester) async {
      for (var index = 0; index < 60; index++) {
        await fixture.book.transactions.create(
          BookTransactionDraft(
            accountId: fixture.osama.id,
            currencyCode: 'YER',
            walletId: fixture.mainWallet.id,
            type: EntryType.debit,
            amountMinor: 100 + index,
            date: '2026-09-20',
          ),
        );
      }
      await open(tester);
      expect(find.byKey(const Key('audit-list')), findsOneWidget);
      // Newest first: the last transaction is on screen, the very first
      // one is far below and not built yet.
      expect(find.text('تم إنشاء العملية TX-000064'), findsOneWidget);
      expect(find.text('تم إنشاء العملية TX-000001'), findsNothing);

      await tester.dragUntilVisible(
        find.text('تم إنشاء العملية TX-000001'),
        find.byKey(const Key('audit-list')),
        const Offset(0, -400),
        maxIteration: 200,
      );

      expect(find.text('تم إنشاء العملية TX-000001'), findsOneWidget);
    });

    testWidgets('an empty book says so', (tester) async {
      // A book nothing was ever written to.
      final book = BookServices(
        repository: InMemoryBookRepository(),
        currencies: testCurrencyRegistry(),
        defaultCurrencyCode: () => 'SAR',
      );
      addTearDown(book.repository.dispose);
      await pumpBookPage(tester, BookAuditLogPage(book: book));

      expect(find.byKey(const Key('audit-empty')), findsOneWidget);
      expect(find.text('لا توجد تعديلات مسجلة'), findsOneWidget);
    });
  });

  group('the archive screen', () {
    Future<void> open(WidgetTester tester) =>
        pumpBookPage(tester, BookArchivePage(book: fixture.book));

    testWidgets('an archive with nothing in it says so', (tester) async {
      await open(tester);

      expect(find.byKey(const Key('archive-empty')), findsOneWidget);
      expect(find.text('الأرشيف فارغ'), findsOneWidget);
    });

    testWidgets('an archived account is listed and can come back', (tester) async {
      await fixture.book.accounts.setStatus(
        fixture.osama.id,
        BookAccountStatus.archived,
      );
      await open(tester);

      expect(find.text('حسابات مؤرشفة (1)'), findsOneWidget);
      expect(find.text('أسامة أخي'), findsOneWidget);
      expect(find.text('YER'), findsNothing);

      await tester.tap(find.byKey(Key('archive-restore-account-${fixture.osama.id}')));
      await tester.pumpAndSettle();

      expect(find.text('أسامة أخي'), findsNothing);
      expect(find.byKey(const Key('archive-empty')), findsOneWidget);
      final summary = await fixture.book.accounts.summary(fixture.osama.id);
      expect(summary!.account.status, BookAccountStatus.active);
    });

    testWidgets('an archived category is listed and can come back', (tester) async {
      final extra = await fixture.book.categories.create(
        const BookCategoryDraft(name: 'مشاريع'),
      );
      await fixture.book.categories.setArchived(extra.id, archived: true);
      await open(tester);

      expect(find.text('تصنيفات مؤرشفة (1)'), findsOneWidget);
      expect(find.text('مشاريع'), findsOneWidget);

      await tester.tap(find.byKey(Key('archive-restore-category-${extra.id}')));
      await tester.pumpAndSettle();

      expect(find.text('مشاريع'), findsNothing);
      expect((await fixture.book.categories.find(extra.id))!.isArchived, isFalse);
    });

    testWidgets('an account under an archived category waits for the category',
        (tester) async {
      await fixture.book.accounts.setStatus(
        fixture.osama.id,
        BookAccountStatus.archived,
      );
      await fixture.book.categories.setArchived(
        fixture.category.id,
        archived: true,
      );
      await open(tester);

      final restoreAccount = find.byKey(
        Key('archive-restore-account-${fixture.osama.id}'),
      );
      expect(find.byKey(Key('archive-blocked-${fixture.osama.id}')), findsOneWidget);
      expect(tester.widget<FilledButton>(restoreAccount).onPressed, isNull);

      await tester.tap(
        find.byKey(Key('archive-restore-category-${fixture.category.id}')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(Key('archive-blocked-${fixture.osama.id}')), findsNothing);
      expect(tester.widget<FilledButton>(restoreAccount).onPressed, isNotNull);
    });

    testWidgets('an archived account still opens to its history', (tester) async {
      await fixture.book.accounts.setStatus(
        fixture.ali.id,
        BookAccountStatus.archived,
      );
      await open(tester);

      await tester.tap(find.byKey(Key('archive-account-${fixture.ali.id}')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('statement-scroll')), findsOneWidget);
      expect(find.text('يوم موت أبي علي'), findsOneWidget);
    });

    testWidgets('archiving something while the screen is open lists it', (
      tester,
    ) async {
      await open(tester);
      expect(find.byKey(const Key('archive-empty')), findsOneWidget);

      await tester.runAsync(
        () => fixture.book.accounts.setStatus(
          fixture.sar.id,
          BookAccountStatus.archived,
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(find.text('حساب سعودي'), findsOneWidget);
    });
  });
}
