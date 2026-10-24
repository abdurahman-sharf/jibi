import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/app/book/book_account_page.dart';
import 'package:jibi/app/book/book_category_page.dart';
import 'package:jibi/app/book/reports/book_report_launcher.dart';
import 'package:jibi/app/book/reports/book_report_preview_page.dart';
import 'package:jibi/app/book/reports/book_reports_hub_page.dart';
import 'package:jibi/app/wallets/wallet_detail_page.dart';
import 'package:jibi/core/errors/app_exception.dart';
import 'package:jibi/core/models/models.dart';
import 'package:jibi/features/book/book.dart';
import 'package:jibi/features/wallets/wallets.dart';

import '../../support/book_harness.dart';
import '../../support/fake_report_exporter.dart';

Future<void> _pumpHub(
  WidgetTester tester,
  BookFixture fixture, {
  bool Function()? pinOk,
}) => pumpBookPage(
  tester,
  Scaffold(body: BookReportsHubPage(book: fixture.book)),
  authorize: pinOk == null
      ? null
      : (context, {required title}) async => pinOk(),
);

Future<void> _tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  group('reports hub', () {
    testWidgets('lists the categories and opens their report choices', (
      tester,
    ) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      await _pumpHub(tester, fixture);

      expect(find.text('التقارير'), findsOneWidget);
      expect(find.text('حسابات اليمن'), findsOneWidget);
      expect(find.text('4 حساب'), findsOneWidget);

      await _tapKey(tester, 'report-category-${fixture.category.id}');
      expect(find.text('تقارير التصنيف'), findsOneWidget);
      expect(find.text('إجمالي المبالغ'), findsOneWidget);
      expect(find.text('تفاصيل جميع المبالغ'), findsOneWidget);
      expect(find.text('إجمالي المبالغ شهرياً'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the accounts view searches and opens the account reports', (
      tester,
    ) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      await _pumpHub(tester, fixture);

      await tester.tap(find.text('الحسابات'));
      await tester.pumpAndSettle();
      expect(find.text('علي أخي'), findsOneWidget);
      expect(find.text('حساب سعودي'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('reports-hub-search')),
        'سعودي',
      );
      await tester.pumpAndSettle();
      expect(find.text('علي أخي'), findsNothing);

      await _tapKey(tester, 'report-account-${fixture.sar.id}');
      expect(find.text('تقارير الحساب'), findsOneWidget);
      expect(find.text('كشف الحساب'), findsOneWidget);
      expect(find.text('كشف الحساب الشهري'), findsOneWidget);
    });

    testWidgets('without categories it explains what to do first', (
      tester,
    ) async {
      final fixture = await BookFixture.create(seed: false);
      addTearDown(fixture.dispose);
      await fixture.book.categories.delete(fixture.category.id);
      await _pumpHub(tester, fixture);

      expect(find.text('لا توجد تقارير بعد'), findsOneWidget);
    });
  });

  group('category reports', () {
    testWidgets('totals are shown per currency and never added together', (
      tester,
    ) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      await _pumpHub(tester, fixture);
      await _tapKey(tester, 'report-category-${fixture.category.id}');
      await _tapKey(tester, 'report-choice-totals');

      expect(find.text('ريال يمني (YER)'), findsOneWidget);
      expect(find.text('ريال سعودي (SAR)'), findsOneWidget);
      // YER: debit 30,100, credit 302,500 -> net 272,400 credit. SAR: 4,850.00.
      expect(find.text('272,400 دائن'), findsOneWidget);
      expect(find.text('4,850.00 مدين'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('details list every account of each currency', (tester) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      await _pumpHub(tester, fixture);
      await _tapKey(tester, 'report-category-${fixture.category.id}');
      await _tapKey(tester, 'report-choice-details');

      expect(find.text('تفاصيل جميع المبالغ'), findsOneWidget);
      expect(find.text('علي أخي'), findsOneWidget);
      expect(find.text('التحويلات الواردة'), findsOneWidget);
      expect(find.text('حساب سعودي'), findsOneWidget);
      expect(find.text('الحساب'), findsWidgets);
      expect(find.text('الإجمالي'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('monthly: the currency filter narrows the report', (
      tester,
    ) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      await _pumpHub(tester, fixture);
      await _tapKey(tester, 'report-category-${fixture.category.id}');
      await _tapKey(tester, 'report-choice-monthly');

      // Two currencies: the chips are offered; pick every period and SAR.
      expect(find.text('كل العملات'), findsOneWidget);
      await _tapKey(tester, 'period-كل الفترات');
      await _tapKey(tester, 'currency-SAR');
      await _tapKey(tester, 'report-options-submit');

      expect(find.text('إجمالي المبالغ شهرياً'), findsOneWidget);
      expect(find.text('ريال سعودي (SAR)'), findsOneWidget);
      expect(find.text('ريال يمني (YER)'), findsNothing);
      expect(find.text('2025-02 · فبراير'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('monthly: a custom period needs at least one date', (
      tester,
    ) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      await pumpBookPage(
        tester,
        CategoryMonthlyOptionsPage(
          book: fixture.book,
          category: fixture.category,
        ),
      );

      await _tapKey(tester, 'period-فترة محددة');
      await _tapKey(tester, 'report-options-submit');
      expect(
        find.text('اختر تاريخ البداية أو النهاية على الأقل.'),
        findsOneWidget,
      );
      // Still on the options page.
      expect(find.byKey(const Key('report-options-submit')), findsOneWidget);
    });
  });

  group('account reports', () {
    testWidgets('the statement page offers the reports and shows the table', (
      tester,
    ) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      await pumpBookPage(
        tester,
        BookAccountPage(book: fixture.book, accountId: fixture.ali.id),
      );

      await _tapKey(tester, 'statement-reports');
      await _tapKey(tester, 'report-choice-statement');
      // Every period is the default.
      await _tapKey(tester, 'report-options-submit');

      expect(find.text('كشف الحساب'), findsWidgets);
      expect(find.text('يوم موت أبي علي (TX-000001)'), findsOneWidget);
      expect(find.text('سداد جزئي (TX-000002)'), findsOneWidget);
      expect(find.text('الإجمالي'), findsOneWidget);
      expect(find.text('الرصيد الافتتاحي للفترة'), findsWidgets);
      expect(find.text('30,100 مدين'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('this month sends the month\'s first and last day', (
      tester,
    ) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      await pumpBookPage(
        tester,
        AccountStatementOptionsPage(
          book: fixture.book,
          account: fixture.ali,
          today: DateTime(2026, 9, 15),
        ),
      );
      await _tapKey(tester, 'period-هذا الشهر');
      await _tapKey(tester, 'report-options-submit');

      expect(find.text('من 2026-09-01 إلى 2026-09-30'), findsOneWidget);
      expect(find.text('سداد جزئي (TX-000002)'), findsOneWidget);
      expect(find.text('يوم موت أبي علي (TX-000001)'), findsNothing);
    });

    testWidgets('a custom range is picked with the date dialog', (
      tester,
    ) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      await pumpBookPage(
        tester,
        AccountStatementOptionsPage(book: fixture.book, account: fixture.ali),
      );
      await _tapKey(tester, 'period-فترة محددة');
      expect(find.text('غير محدد'), findsNWidgets(2));

      await _tapKey(tester, 'report-from');
      expect(find.byType(DatePickerDialog), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(DatePickerDialog),
          matching: find.byType(TextButton),
        ).last,
      );
      await tester.pumpAndSettle();
      // The date is set and can be cleared again.
      expect(find.text('غير محدد'), findsOneWidget);
      expect(find.byKey(const Key('report-from-clear')), findsOneWidget);
      await _tapKey(tester, 'report-from-clear');
      expect(find.text('غير محدد'), findsNWidgets(2));
    });

    testWidgets('the monthly statement shows the month\'s opening and closing', (
      tester,
    ) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      await pumpBookPage(
        tester,
        AccountMonthlyOptionsPage(
          book: fixture.book,
          account: fixture.ali,
          today: DateTime(2024, 12, 20),
        ),
      );
      await tester.tap(find.byKey(const Key('report-options-submit')));
      await tester.pumpAndSettle();

      expect(find.text('كشف الحساب الشهري'), findsOneWidget);
      expect(find.text('يوم موت أبي علي (TX-000001)'), findsOneWidget);
      expect(find.text('الرصيد بداية الشهر'), findsWidgets);
      expect(find.text('الرصيد نهاية الشهر'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the category page has a reports button', (tester) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      await pumpBookPage(
        tester,
        BookCategoryPage(book: fixture.book, categoryId: fixture.category.id),
      );
      await _tapKey(tester, 'category-reports');
      expect(find.text('تقارير التصنيف'), findsOneWidget);
    });
  });

  group('wallet reports', () {
    testWidgets('the wallet page offers the report and shows the table', (
      tester,
    ) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      final wallet = await fixture.book.wallets.create(
        WalletDraft.single(
          name: 'الصندوق',
          currencyCode: 'YER',
          openingMinor: 1000,
        ),
      );
      await fixture.book.walletTransactions.deposit(
        WalletDepositDraft(walletId: wallet.id, amountMinor: 500, date: '2025-01-10'),
      );
      await pumpBookPage(
        tester,
        WalletDetailPage(book: fixture.book, walletId: wallet.id),
      );

      await _tapKey(tester, 'wallet-reports');
      // A wallet has only one report kind, so the options page opens at once.
      await _tapKey(tester, 'report-options-submit');

      expect(find.text('كشف المحفظة'), findsWidgets);
      expect(find.text('الرصيد الافتتاحي للفترة'), findsWidgets);
      expect(find.text('الإجمالي'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a custom period narrows the movements shown', (tester) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      final wallet = await fixture.book.wallets.create(
        WalletDraft.single(
          name: 'الصندوق',
          currencyCode: 'YER',
        ),
      );
      await fixture.book.walletTransactions.deposit(
        WalletDepositDraft(walletId: wallet.id, amountMinor: 500, date: '2025-01-10'),
      );
      await fixture.book.walletTransactions.deposit(
        WalletDepositDraft(walletId: wallet.id, amountMinor: 700, date: '2025-06-01'),
      );
      await pumpBookPage(
        tester,
        WalletStatementOptionsPage(
          book: fixture.book,
          wallet: wallet,
          today: DateTime(2026, 9, 15),
        ),
      );
      await _tapKey(tester, 'period-هذا الشهر');
      await _tapKey(tester, 'report-options-submit');

      expect(find.text('من 2026-09-01 إلى 2026-09-30'), findsOneWidget);
      // Both deposits (January and June 2025) are before the period, so they
      // are carried into the opening balance and no movement row is shown.
      expect(find.textContaining('إيداع'), findsNothing);
      expect(find.text('1,200'), findsWidgets);
    });
  });

  group('preview and export', () {
    late FakeReportExporter exporter;
    var pinOk = true;

    Future<BookFixture> open(WidgetTester tester, {bool withExporter = true}) async {
      exporter = FakeReportExporter();
      pinOk = true;
      final fixture = await BookFixture.create(
        exporter: withExporter ? exporter : null,
      );
      addTearDown(fixture.dispose);
      await pumpBookPage(
        tester,
        BookReportPreviewPage(
          book: fixture.book,
          build: () => fixture.book.reports.accountStatement(fixture.ali.id),
        ),
        authorize: (context, {required title}) async => pinOk,
      );
      return fixture;
    }

    testWidgets('PDF and Excel go through the share sheet', (tester) async {
      await open(tester);
      await _tapKey(tester, 'report-export-pdf');
      await _tapKey(tester, 'report-export-xlsx');
      expect(exporter.calls, ['file:pdf:chooser', 'file:xlsx:chooser']);
      // The exported document is the one on screen.
      expect(exporter.documents.first.title, 'كشف الحساب');
    });

    testWidgets('WhatsApp offers the PDF or a text summary', (tester) async {
      await open(tester);
      await _tapKey(tester, 'report-export-whatsapp');
      await _tapKey(tester, 'whatsapp-pdf');
      await _tapKey(tester, 'report-export-whatsapp');
      await _tapKey(tester, 'whatsapp-text');
      expect(exporter.calls, ['file:pdf:whatsApp', 'text:whatsApp']);
    });

    testWidgets('share sends the text summary to any app', (tester) async {
      await open(tester);
      await _tapKey(tester, 'report-export-text');
      expect(exporter.calls, ['text:chooser']);
    });

    testWidgets('"حفظ وطباعة" offers saving the PDF or Excel and printing', (
      tester,
    ) async {
      await open(tester);

      await _tapKey(tester, 'report-export-more');
      expect(find.byKey(const Key('report-more-save-pdf')), findsOneWidget);
      expect(find.byKey(const Key('report-more-save-xlsx')), findsOneWidget);
      expect(find.byKey(const Key('report-more-print')), findsOneWidget);

      await _tapKey(tester, 'report-more-save-pdf');
      expect(find.text('تم حفظ الملف.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await _tapKey(tester, 'report-export-more');
      await _tapKey(tester, 'report-more-save-xlsx');
      await tester.pump(const Duration(seconds: 5));
      await _tapKey(tester, 'report-export-more');
      await _tapKey(tester, 'report-more-print');

      expect(exporter.calls, ['save:pdf', 'save:xlsx', 'print']);
      // Always the document on screen.
      expect(exporter.documents.first.title, 'كشف الحساب');
    });

    testWidgets('backing out of the save screen says nothing', (tester) async {
      await open(tester);
      exporter.saveResult = false;

      await _tapKey(tester, 'report-export-more');
      await _tapKey(tester, 'report-more-save-pdf');

      expect(exporter.calls, ['save:pdf']);
      expect(find.text('تم حفظ الملف.'), findsNothing);
    });

    testWidgets('saving and printing ask for the PIN too', (tester) async {
      await open(tester);
      pinOk = false;

      await _tapKey(tester, 'report-export-more');
      await _tapKey(tester, 'report-more-save-pdf');
      await _tapKey(tester, 'report-export-more');
      await _tapKey(tester, 'report-more-print');

      expect(exporter.calls, isEmpty);
    });

    testWidgets('a print failure says why', (tester) async {
      await open(tester);
      exporter.failure = const StorageException(
        code: 'report_export_failed',
        userMessage: 'تعذر إنشاء ملف التقرير. حاول مرة أخرى.',
      );

      await _tapKey(tester, 'report-export-more');
      await _tapKey(tester, 'report-more-print');

      expect(find.text('تعذر إنشاء ملف التقرير. حاول مرة أخرى.'), findsOneWidget);
    });

    testWidgets('a wrong PIN exports nothing', (tester) async {
      await open(tester);
      pinOk = false;
      await _tapKey(tester, 'report-export-pdf');
      await _tapKey(tester, 'report-export-text');
      expect(exporter.calls, isEmpty);
    });

    testWidgets('a failed export says why and can be tried again', (
      tester,
    ) async {
      await open(tester);
      exporter.failure = const StorageException(
        code: 'report_export_failed',
        userMessage: 'تعذر إنشاء ملف التقرير. حاول مرة أخرى.',
      );
      await _tapKey(tester, 'report-export-pdf');
      expect(find.text('تعذر إنشاء ملف التقرير. حاول مرة أخرى.'), findsOneWidget);
      // The buttons are back.
      exporter.failure = null;
      await tester.pump(const Duration(seconds: 5));
      await _tapKey(tester, 'report-export-pdf');
      expect(exporter.calls, ['file:pdf:chooser', 'file:pdf:chooser']);
    });

    testWidgets('without an exporter or a PIN gate there are no export buttons', (
      tester,
    ) async {
      await open(tester, withExporter: false);
      expect(find.byKey(const Key('report-export-pdf')), findsNothing);
      // The report itself is still there.
      expect(find.byKey(const Key('report-view')), findsOneWidget);
    });

    testWidgets('a report that cannot be built shows the reason and retries', (
      tester,
    ) async {
      var attempts = 0;
      final fixture = await BookFixture.create(exporter: FakeReportExporter());
      addTearDown(fixture.dispose);
      await pumpBookPage(
        tester,
        BookReportPreviewPage(
          book: fixture.book,
          build: () async {
            attempts++;
            if (attempts == 1) {
              throw const ValidationException(
                code: 'invalid_report_range',
                userMessage: 'تاريخ البداية يجب أن يسبق تاريخ النهاية.',
              );
            }
            return fixture.book.reports.accountStatement(fixture.ali.id);
          },
        ),
      );
      expect(
        find.text('تاريخ البداية يجب أن يسبق تاريخ النهاية.'),
        findsOneWidget,
      );
      await tester.tap(find.text('إعادة المحاولة'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('report-view')), findsOneWidget);
      expect(attempts, 2);
    });

    testWidgets('a long statement is built lazily and scrolls', (tester) async {
      final fixture = await BookFixture.create(exporter: FakeReportExporter());
      addTearDown(fixture.dispose);
      for (var index = 1; index <= 300; index++) {
        await fixture.book.transactions.create(
          BookTransactionDraft(
            accountId: fixture.osama.id,
            currencyCode: 'YER',
            walletId: fixture.mainWallet.id,
            type: EntryType.debit,
            amountMinor: index,
            date: '2025-01-${(index % 28 + 1).toString().padLeft(2, '0')}',
            details: 'دفعة $index',
          ),
        );
      }
      await pumpBookPage(
        tester,
        BookReportPreviewPage(
          book: fixture.book,
          build: () => fixture.book.reports.accountStatement(fixture.osama.id),
        ),
        size: const Size(390, 844),
      );
      // Only the rows near the screen are built, and the totals (the last
      // row) are still far below.
      final built = find.textContaining('دفعة').evaluate().length;
      expect(built, greaterThan(0));
      expect(built, lessThan(60));
      expect(find.text('الإجمالي'), findsNothing);
      await tester.fling(
        find.byKey(const Key('report-view')),
        const Offset(0, -40000),
        6000,
      );
      await tester.pumpAndSettle();
      expect(find.text('الإجمالي'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
