import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/app/book/book_account_page.dart';
import 'package:jibi/app/book/book_categories_page.dart';
import 'package:jibi/app/book/book_category_management_page.dart';
import 'package:jibi/app/book/book_category_page.dart';
import 'package:jibi/app/book/book_preferences_scope.dart';
import 'package:jibi/core/models/models.dart';
import 'package:jibi/features/book/book.dart';
import 'package:jibi/shared/theme/jibi_theme.dart';

import '../../support/book_harness.dart';

const _wording = BookPreferences(
  labels: BookLabels(
    debit: 'مستحق لي',
    credit: 'مستحق علي',
    debitHint: '',
    creditHint: '',
  ),
);

/// Like `pumpBookPage`, but the app carries the [preferences] the way the real
/// app does: above the navigator, so pushed pages and sheets see them too.
Future<ValueNotifier<BookPreferences>> _pump(
  WidgetTester tester,
  Widget page,
  BookPreferences preferences,
) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final notifier = ValueNotifier(preferences);
  addTearDown(notifier.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: JibiTheme.light(),
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => ValueListenableBuilder<BookPreferences>(
        valueListenable: notifier,
        builder: (context, value, _) => BookPreferencesScope(
          preferences: value,
          child: Directionality(textDirection: TextDirection.rtl, child: child!),
        ),
      ),
      home: page,
    ),
  );
  await tester.pumpAndSettle();
  return notifier;
}

Future<List<BookTransaction>> _rows(BookFixture f, BookAccount a) async =>
    (await f.book.repository.transactionPage(
      a.id,
      newestFirst: false,
      limit: 500,
    )).items;

Finder _inside(String key, String text) => find.descendant(
  of: find.byKey(Key(key)),
  matching: find.text(text),
);

void main() {
  late BookFixture fixture;

  setUp(() async {
    fixture = await BookFixture.create();
  });

  tearDown(() => fixture.dispose());

  Widget statement() =>
      BookAccountPage(book: fixture.book, accountId: fixture.ali.id);

  group('side wording', () {
    testWidgets('the statement uses the custom words', (tester) async {
      await _pump(tester, statement(), _wording);

      expect(_inside('total-net', '30,100 مستحق لي'), findsOneWidget);
      expect(find.text('إجمالي مستحق لي'), findsOneWidget);
      expect(find.text('إجمالي مستحق علي'), findsOneWidget);
      expect(find.text('مدين'), findsNothing);
      expect(find.text('دائن'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a change made while the page is open shows at once', (
      tester,
    ) async {
      final notifier = await _pump(
        tester,
        statement(),
        BookPreferences.standard,
      );
      expect(_inside('total-net', '30,100 مدين'), findsOneWidget);

      notifier.value = _wording;
      await tester.pumpAndSettle();

      expect(_inside('total-net', '30,100 مستحق لي'), findsOneWidget);
      expect(_inside('total-net', '30,100 مدين'), findsNothing);
    });

    testWidgets('the form and the filter sheet use them too', (tester) async {
      await _pump(tester, statement(), _wording);

      await tester.tap(find.byKey(const Key('add-transaction-button')));
      await tester.pumpAndSettle();
      expect(find.text('مستحق لي'), findsOneWidget);
      expect(find.text('مستحق علي'), findsOneWidget);
      expect(find.text('مدين (لنا)'), findsNothing);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('statement-filters')));
      await tester.pumpAndSettle();
      expect(find.text('مستحق لي فقط'), findsOneWidget);
      expect(find.text('مستحق علي فقط'), findsOneWidget);
    });

    testWidgets('the standard hints stay when nothing is renamed', (
      tester,
    ) async {
      await _pump(tester, statement(), BookPreferences.standard);

      await tester.tap(find.byKey(const Key('add-transaction-button')));
      await tester.pumpAndSettle();

      expect(find.text('مدين (لنا)'), findsOneWidget);
      expect(find.text('دائن (علينا)'), findsOneWidget);
    });

    testWidgets('the details sheet and the shared text use them', (
      tester,
    ) async {
      final rows = await _rows(fixture, fixture.ali);
      await _pump(tester, statement(), _wording);

      await tester.tap(find.byKey(Key('tx-row-${rows.first.id}')));
      await tester.pumpAndSettle();

      expect(find.text('تفاصيل العملية'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('مستحق لي'),
        ),
        findsWidgets,
      );
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('مدين'),
        ),
        findsNothing,
      );
    });
  });

  group('long custom wording', () {
    // The longest word the settings accept must never overflow a screen.
    final longWording = BookPreferences(
      labels: BookLabels(
        debit: 'مستحق لي عند الآخرين جداً',
        credit: 'مستحق علي للآخرين جداً',
        debitHint: '',
        creditHint: '',
      ),
    );

    testWidgets('the categories root fits', (tester) async {
      await _pump(
        tester,
        Scaffold(body: BookCategoriesPage(book: fixture.book)),
        longWording,
      );

      expect(find.textContaining('مستحق لي'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the category page fits', (tester) async {
      await _pump(
        tester,
        BookCategoryPage(book: fixture.book, categoryId: fixture.category.id),
        longWording,
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('the category management page fits', (tester) async {
      await _pump(
        tester,
        BookCategoryManagementPage(book: fixture.book),
        longWording,
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('the statement and its form fit', (tester) async {
      await _pump(tester, statement(), longWording);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('add-transaction-button')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('date and time', () {
    const slash = BookPreferences(dateFormat: DateDisplayFormat.dayMonthYearSlash);

    testWidgets('the table writes dates the chosen way', (tester) async {
      await _pump(tester, statement(), slash);

      expect(find.text('20/09/2026'), findsOneWidget);
      expect(find.text('13/12/2024'), findsOneWidget);
      expect(find.text('2026-09-20'), findsNothing);
    });

    testWidgets('a date typed the way it is shown finds its transaction', (
      tester,
    ) async {
      await _pump(tester, statement(), slash);

      await tester.tap(find.byKey(const Key('statement-search')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('statement-query')),
        '13/12/2024',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.text('العمليات: 1'), findsOneWidget);
      expect(find.text('#TX-000001'), findsOneWidget);
      expect(find.text('#TX-000002'), findsNothing);
    });

    testWidgets('the details sheet writes the date the chosen way', (
      tester,
    ) async {
      final rows = await _rows(fixture, fixture.ali);
      await _pump(tester, statement(), slash);

      await tester.tap(find.byKey(Key('tx-row-${rows.first.id}')));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('13/12/2024'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the time shows under the date only when asked', (
      tester,
    ) async {
      final rows = await _rows(fixture, fixture.ali);
      final timeKey = Key('row-time-${rows.first.id}');

      final notifier = await _pump(tester, statement(), BookPreferences.standard);
      expect(find.byKey(timeKey), findsOneWidget);

      notifier.value = const BookPreferences(showTime: false);
      await tester.pumpAndSettle();
      expect(find.byKey(timeKey), findsNothing);
    });
  });

  group('hidden balances', () {
    const hidden = BookPreferences(hideBalances: true);

    testWidgets('the statement hides balances and totals, not amounts', (
      tester,
    ) async {
      await _pump(tester, statement(), hidden);

      expect(_inside('statement-balance', hiddenAmountText), findsOneWidget);
      expect(_inside('total-debit', 'YER $hiddenAmountText'), findsOneWidget);
      expect(_inside('total-credit', 'YER $hiddenAmountText'), findsOneWidget);
      expect(
        _inside('total-net', '$hiddenAmountText مدين'),
        findsOneWidget,
      );
      expect(find.text('30,100'), findsNothing);
      // The running balance of each row is hidden; the amounts stay.
      expect(find.text(hiddenAmountText), findsNWidgets(3));
      expect(find.text('30,000'), findsOneWidget);
      expect(find.text('100'), findsOneWidget);
    });

    testWidgets('turning it off brings the numbers back', (tester) async {
      final notifier = await _pump(tester, statement(), hidden);
      expect(_inside('statement-balance', hiddenAmountText), findsOneWidget);

      notifier.value = BookPreferences.standard;
      await tester.pumpAndSettle();

      expect(_inside('statement-balance', '30,100'), findsOneWidget);
      expect(_inside('total-net', '30,100 مدين'), findsOneWidget);
    });

    testWidgets('the category page hides its summary and its account balances', (
      tester,
    ) async {
      await _pump(
        tester,
        BookCategoryPage(book: fixture.book, categoryId: fixture.category.id),
        hidden,
      );

      expect(
        _inside('category-summary', hiddenAmountText),
        findsWidgets,
      );
      expect(find.text('30,100'), findsNothing);
      expect(find.text('302,500'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the details sheet hides the balance after the transaction', (
      tester,
    ) async {
      final rows = await _rows(fixture, fixture.ali);
      await _pump(tester, statement(), hidden);

      await tester.tap(find.byKey(Key('tx-row-${rows.first.id}')));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.textContaining('$hiddenAmountText YER'),
        ),
        findsOneWidget,
      );
    });
  });

  group('entry preferences', () {
    testWidgets('the order of the transactions starts as chosen', (
      tester,
    ) async {
      await _pump(
        tester,
        statement(),
        const BookPreferences(newestFirst: false),
      );

      final oldest = tester.getTopLeft(find.text('#TX-000001')).dy;
      final newest = tester.getTopLeft(find.text('#TX-000002')).dy;
      expect(oldest, lessThan(newest));
      expect(find.text('الأقدم أولاً'), findsOneWidget);
    });

    testWidgets('a new transaction starts on the chosen side', (tester) async {
      await _pump(
        tester,
        statement(),
        const BookPreferences(defaultEntryType: EntryType.credit),
      );

      await tester.tap(find.byKey(const Key('add-transaction-button')));
      await tester.pumpAndSettle();

      final selected = tester
          .widget<SegmentedButton<EntryType>>(find.byKey(const Key('tx-type')))
          .selected;
      expect(selected, {EntryType.credit});
    });

    testWidgets('editing keeps the transaction\'s own side', (tester) async {
      final rows = await _rows(fixture, fixture.ali);
      await _pump(
        tester,
        statement(),
        const BookPreferences(defaultEntryType: EntryType.credit),
      );

      await tester.tap(find.byKey(Key('tx-row-${rows.first.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('details-edit')));
      await tester.pumpAndSettle();

      final selected = tester
          .widget<SegmentedButton<EntryType>>(find.byKey(const Key('tx-type')))
          .selected;
      expect(selected, {EntryType.debit});
    });

    testWidgets('with confirmation off a delete happens at once and can be undone',
        (tester) async {
      final rows = await _rows(fixture, fixture.ali);
      await _pump(
        tester,
        statement(),
        const BookPreferences(confirmBeforeDelete: false),
      );

      await tester.tap(find.byKey(Key('tx-row-${rows.first.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('details-delete')));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'سيؤدي حذف هذه العملية إلى تغيير رصيد الحساب والعمليات التالية. '
          'هل تريد المتابعة؟',
        ),
        findsNothing,
      );
      expect(find.text('تم حذف العملية'), findsOneWidget);
      expect(await _rows(fixture, fixture.ali), hasLength(1));

      await tester.tap(find.text('تراجع'));
      await tester.pumpAndSettle();
      expect(await _rows(fixture, fixture.ali), hasLength(2));
    });

    testWidgets('with confirmation on it still asks', (tester) async {
      final rows = await _rows(fixture, fixture.ali);
      await _pump(tester, statement(), BookPreferences.standard);

      await tester.tap(find.byKey(Key('tx-row-${rows.first.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('details-delete')));
      await tester.pumpAndSettle();

      expect(find.text('حذف العملية'), findsOneWidget);
      expect(await _rows(fixture, fixture.ali), hasLength(2));
    });
  });
}
