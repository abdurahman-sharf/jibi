import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/app/book/book_account_page.dart';
import 'package:jibi/app/book/book_archive_page.dart';
import 'package:jibi/app/book/book_category_page.dart';
import 'package:jibi/app/book/reports/book_report_launcher.dart';
import 'package:jibi/core/models/models.dart';
import 'package:jibi/features/book/book.dart';
import 'package:jibi/features/wallets/wallets.dart';

import '../../support/book_harness.dart';

/// The screens of an account that uses several currencies: «محمد خالد» is ONE
/// account with an independent balance per currency, never one total.
const _tall = Size(390, 2400);

Future<BookAccount> _mohammed(BookFixture fixture) async {
  final wallet = await fixture.ensureMainWallet();
  final account = await fixture.book.accounts.create(
    BookAccountDraft(
      categoryId: fixture.category.id,
      name: 'محمد خالد',
      openings: const [
        BookAccountOpeningDraft(
          currencyCode: 'SAR',
          openingMinor: 30000,
          openingType: OpeningType.credit,
        ),
      ],
    ),
  );
  Future<void> tx(String code, EntryType type, int minor, String date) =>
      fixture.book.transactions.create(
        BookTransactionDraft(
          accountId: account.id,
          currencyCode: code,
          type: type,
          amountMinor: minor,
          date: date,
          details: 'حركة $code',
          walletId: wallet.id,
        ),
      );
  await tx('YER', EntryType.debit, 50000, '2025-01-01');
  await tx('YER', EntryType.credit, 25000, '2025-01-02');
  await tx('SAR', EntryType.debit, 10000, '2025-01-03');
  await tx('USD', EntryType.debit, 2000, '2025-01-04');
  return account;
}

Future<void> _openAccount(
  WidgetTester tester,
  BookFixture fixture,
  BookAccount account,
) => pumpBookPage(
  tester,
  BookAccountPage(book: fixture.book, accountId: account.id),
  size: _tall,
);

Future<void> _tapChip(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

String _textOf(WidgetTester tester, Finder finder) => tester
    .widgetList<Text>(
      find.descendant(of: finder, matching: find.byType(Text)),
    )
    .map((text) => text.data ?? '')
    .join(' ');

void main() {
  group('the account screen', () {
    testWidgets('shows a balance per currency and no single total', (tester) async {
      final fixture = await BookFixture.create(seed: false);
      addTearDown(fixture.dispose);
      final account = await _mohammed(fixture);
      await _openAccount(tester, fixture, account);

      final balance = find.byKey(const Key('statement-balance'));
      // YER 25,000 debit; SAR 300.00 credit opening + 100.00 debit = 200.00
      // credit; USD 20.00 debit — each on its own row.
      expect(
        _textOf(tester, find.descendant(of: balance, matching: find.byKey(const Key('balance-line-YER')))),
        allOf(contains('25,000'), contains('YER'), contains('مدين')),
      );
      expect(
        _textOf(tester, find.descendant(of: balance, matching: find.byKey(const Key('balance-line-SAR')))),
        allOf(contains('200.00'), contains('SAR'), contains('دائن')),
      );
      expect(
        _textOf(tester, find.descendant(of: balance, matching: find.byKey(const Key('balance-line-USD')))),
        allOf(contains('20.00'), contains('USD'), contains('مدين')),
      );
      // Nothing adds them up: there is no 25,000 + 200 + 20 anywhere.
      for (final mixed in ['25,220', '25,020', '24,820', '25,180']) {
        expect(find.textContaining(mixed), findsNothing, reason: mixed);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('an account with nothing yet says so instead of showing a zero',
        (tester) async {
      final fixture = await BookFixture.create(seed: false);
      addTearDown(fixture.dispose);
      final empty = await fixture.book.accounts.create(
        BookAccountDraft(categoryId: fixture.category.id, name: 'جديد'),
      );
      await _openAccount(tester, fixture, empty);

      expect(find.byKey(const Key('balance-lines-empty')), findsOneWidget);
      expect(find.byKey(const Key('currency-filter')), findsNothing);
    });

    testWidgets('every row names its currency', (tester) async {
      final fixture = await BookFixture.create(seed: false);
      addTearDown(fixture.dispose);
      final account = await _mohammed(fixture);
      await _openAccount(tester, fixture, account);

      expect(find.text('YER · مدين'), findsOneWidget);
      expect(find.text('YER · دائن'), findsOneWidget);
      expect(find.text('SAR · مدين'), findsOneWidget);
      expect(find.text('USD · مدين'), findsOneWidget);
    });

    testWidgets('the currency chips filter the list, the count and the totals',
        (tester) async {
      final fixture = await BookFixture.create(seed: false);
      addTearDown(fixture.dispose);
      final account = await _mohammed(fixture);
      await _openAccount(tester, fixture, account);

      // كل العملات: 4 rows, and a totals row per currency.
      expect(find.text('العمليات: 4'), findsOneWidget);
      expect(find.byKey(const Key('total-net-YER')), findsOneWidget);
      expect(find.byKey(const Key('total-net-SAR')), findsOneWidget);
      expect(find.byKey(const Key('total-net-USD')), findsOneWidget);

      await _tapChip(tester, const Key('currency-filter-YER'));
      expect(find.text('العمليات: 2'), findsOneWidget);
      expect(find.text('حركة YER'), findsNWidgets(2));
      expect(find.text('حركة SAR'), findsNothing);
      // One currency: the familiar debit / net / credit bar of that currency.
      expect(
        find.descendant(
          of: find.byKey(const Key('total-net')),
          matching: find.text('25,000 مدين'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('total-net-SAR')), findsNothing);

      await _tapChip(tester, const Key('currency-filter-SAR'));
      expect(find.text('العمليات: 1'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('total-net')),
          matching: find.text('200.00 دائن'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('total-credit')),
          matching: find.text('SAR 300.00'),
        ),
        findsOneWidget,
        reason: 'the opening credit belongs to SAR alone',
      );

      await _tapChip(tester, const Key('currency-filter-all'));
      expect(find.text('العمليات: 4'), findsOneWidget);
    });

    testWidgets('a single-currency account has no currency chips and the '
        'usual totals bar', (tester) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      await _openAccount(tester, fixture, fixture.ali);

      expect(find.byKey(const Key('currency-filter')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('total-net')),
          matching: find.text('30,100 مدين'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('an amount typed in the search is read in each currency',
        (tester) async {
      final fixture = await BookFixture.create(seed: false);
      addTearDown(fixture.dispose);
      final account = await _mohammed(fixture);
      await _openAccount(tester, fixture, account);

      await tester.tap(find.byKey(const Key('statement-search')));
      await tester.pumpAndSettle();
      // 100 = 100.00 SAR (10000 minor), but only 100 minor in YER: exactly the
      // SAR row matches, never a YER amount that merely looks alike.
      await tester.enterText(find.byKey(const Key('statement-query')), '100');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('حركة SAR'), findsOneWidget);
      expect(find.text('حركة YER'), findsNothing);
    });
  });

  group('the transaction form', () {
    /// «إضافة جديد» from the account's statement, optionally with the list
    /// already filtered to one currency (which the form then starts on), or the
    /// edit form of [transaction] from its details sheet.
    Future<void> openForm(
      WidgetTester tester,
      BookFixture fixture,
      BookAccount account, {
      BookTransaction? transaction,
      String? initialCurrencyCode,
    }) async {
      await _openAccount(tester, fixture, account);
      if (transaction != null) {
        await tester.ensureVisible(find.byKey(Key('tx-row-${transaction.id}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('tx-row-${transaction.id}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('details-edit')));
      } else {
        if (initialCurrencyCode != null) {
          await _tapChip(tester, Key('currency-filter-$initialCurrencyCode'));
        }
        await tester.tap(find.byKey(const Key('add-transaction-button')));
      }
      await tester.pumpAndSettle();
    }

    ChoiceChip chip(WidgetTester tester, String code) =>
        tester.widget<ChoiceChip>(find.byKey(Key('tx-currency-$code')));

    testWidgets('offers every active currency and starts on the only one the '
        'account uses', (tester) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      await openForm(tester, fixture, fixture.ali);

      // The fixture's registry has ten active currencies.
      expect(find.byKey(const Key('tx-currency')), findsOneWidget);
      for (final code in ['YER', 'SAR', 'USD']) {
        expect(find.byKey(Key('tx-currency-$code')), findsOneWidget);
      }
      // علي أخي only ever used YER.
      expect(chip(tester, 'YER').selected, isTrue);
      expect(chip(tester, 'SAR').selected, isFalse);
    });

    testWidgets('an account with several currencies starts on the base one, or '
        'the one asked for', (tester) async {
      final fixture = await BookFixture.create(seed: false);
      addTearDown(fixture.dispose);
      final account = await _mohammed(fixture);

      await openForm(tester, fixture, account);
      // The fixture's base currency is SAR (three currencies, no single one).
      expect(chip(tester, 'SAR').selected, isTrue);

      // Filtered to USD on the statement, the form starts on USD.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await openForm(tester, fixture, account, initialCurrencyCode: 'USD');
      expect(chip(tester, 'USD').selected, isTrue);
      expect(chip(tester, 'SAR').selected, isFalse);
    });

    testWidgets('a SAR transaction from نقدًا moves the account\'s SAR and the '
        'wallet\'s SAR only', (tester) async {
      final fixture = await BookFixture.create(seed: false);
      addTearDown(fixture.dispose);
      final account = await _mohammed(fixture);
      final main = await fixture.ensureMainWallet();
      Future<int> cash(String code) async =>
          (await fixture.book.wallets.summary(main.id))!.balanceOf(code);
      final yerBefore = await cash('YER');
      final sarBefore = await cash('SAR');

      await openForm(tester, fixture, account, initialCurrencyCode: 'SAR');
      await tester.enterText(find.byKey(const Key('tx-amount')), '12.5');
      await tester.pump();
      // SAR keeps two decimals.
      expect(find.text('12.5'), findsOneWidget);
      await tester.dragUntilVisible(
        find.byKey(const Key('save-button')),
        find.byType(ListView),
        const Offset(0, -300),
        maxIteration: 50,
      );
      await tester.ensureVisible(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();

      final saved = (await fixture.book.repository.transactionPage(
        account.id,
        filter: const BookTransactionFilter(currencyCode: 'SAR'),
        newestFirst: true,
        limit: 1,
      )).items.single;
      expect(saved.currencyCode, 'SAR');
      expect(saved.amountMinor, 1250);
      expect(await cash('SAR'), sarBefore - 1250);
      expect(await cash('YER'), yerBefore);
      final line = (await fixture.book.accounts.summary(account.id))!;
      expect(line.totalsOf('YER')!.netMinor, 25000);
      expect(line.totalsOf('USD')!.netMinor, 2000);
    });

    testWidgets('switching currency re-applies its decimals to what was typed',
        (tester) async {
      final fixture = await BookFixture.create(seed: false);
      addTearDown(fixture.dispose);
      final account = await _mohammed(fixture);
      await openForm(tester, fixture, account, initialCurrencyCode: 'SAR');

      await tester.enterText(find.byKey(const Key('tx-amount')), '1234.56');
      await tester.pump();
      expect(find.text('1,234.56'), findsOneWidget);
      await tester.tap(find.byKey(const Key('tx-currency-YER')));
      await tester.pumpAndSettle();
      // YER has no decimals: the fraction is dropped, not left to fail on save.
      expect(find.text('1,234'), findsOneWidget);
      expect(find.text('1,234.56'), findsNothing);
    });

    testWidgets('editing a transaction can move it to another currency',
        (tester) async {
      final fixture = await BookFixture.create(seed: false);
      addTearDown(fixture.dispose);
      final account = await _mohammed(fixture);
      final main = await fixture.ensureMainWallet();
      final yerRow = (await fixture.book.repository.transactionPage(
        account.id,
        filter: const BookTransactionFilter(currencyCode: 'YER'),
        newestFirst: false,
      )).items.first;
      Future<int> cash(String code) async =>
          (await fixture.book.wallets.summary(main.id))!.balanceOf(code);
      final yerCashBefore = await cash('YER');

      await openForm(tester, fixture, account, transaction: yerRow);
      expect(chip(tester, 'YER').selected, isTrue);
      await tester.tap(find.byKey(const Key('tx-currency-USD')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('tx-amount')), '5');
      await tester.dragUntilVisible(
        find.byKey(const Key('save-button')),
        find.byType(ListView),
        const Offset(0, -300),
        maxIteration: 50,
      );
      await tester.ensureVisible(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();

      final moved = (await fixture.book.transactions.find(yerRow.id))!;
      expect(moved.currencyCode, 'USD');
      expect(moved.amountMinor, 500);
      // The old YER effect was reversed (a 50,000 debit that lowered cash),
      // and the new one applied in USD.
      expect(await cash('YER'), yerCashBefore + 50000);
      expect(await cash('USD'), -2000 - 500);
      final summary = (await fixture.book.accounts.summary(account.id))!;
      expect(summary.totalsOf('YER')!.netMinor, -25000);
      expect(summary.totalsOf('USD')!.netMinor, 2500);
    });

  });

  group('the payment method follows the currency', () {
    /// «محفظة الراجحي» holds SAR only; the main wallet holds YER, SAR and USD.
    Future<Wallet> rajhi(BookFixture fixture) => fixture.book.wallets.create(
      WalletDraft.single(name: 'محفظة الراجحي', currencyCode: 'SAR'),
    );

    /// «إضافة جديد» from the statement (optionally already filtered to one
    /// currency), or the edit form of [transaction].
    Future<void> openForm(
      WidgetTester tester,
      BookFixture fixture,
      BookAccount account, {
      BookTransaction? transaction,
      String? filterCurrency,
    }) async {
      await _openAccount(tester, fixture, account);
      if (transaction != null) {
        await tester.ensureVisible(find.byKey(Key('tx-row-${transaction.id}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('tx-row-${transaction.id}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('details-edit')));
      } else {
        if (filterCurrency != null) {
          await _tapChip(tester, Key('currency-filter-$filterCurrency'));
        }
        await tester.tap(find.byKey(const Key('add-transaction-button')));
      }
      await tester.pumpAndSettle();
    }

    Future<void> pickCurrency(WidgetTester tester, String code) async {
      await tester.ensureVisible(find.byKey(Key('tx-currency-$code')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('tx-currency-$code')));
      await tester.pumpAndSettle();
    }

    List<String> labels(WidgetTester tester) => [
      for (final chip in tester.widgetList<ChoiceChip>(
        find.descendant(
          of: find.byKey(const Key('tx-payment-method')),
          matching: find.byType(ChoiceChip),
        ),
      ))
        (chip.label as Text).data!,
    ];

    Future<void> tapSave(WidgetTester tester) async {
      await tester.dragUntilVisible(
        find.byKey(const Key('save-button')),
        find.byType(ListView),
        const Offset(0, -300),
        maxIteration: 50,
      );
      await tester.ensureVisible(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();
    }

    Future<List<String>> held(BookFixture fixture, String walletId) async => [
      for (final b in await fixture.book.repository.walletBalancesOf(walletId))
        b.currencyCode,
    ];

    testWidgets('a SAR wallet is offered for a SAR transaction and not for a '
        'USD one', (tester) async {
      final fixture = await BookFixture.create(seed: false);
      addTearDown(fixture.dispose);
      final account = await _mohammed(fixture);
      await rajhi(fixture);

      await openForm(tester, fixture, account, filterCurrency: 'SAR');
      expect(labels(tester), ['نقدًا', 'محفظة الراجحي']);

      await pickCurrency(tester, 'USD');
      expect(labels(tester), ['نقدًا']);
      await pickCurrency(tester, 'YER');
      expect(labels(tester), ['نقدًا']);
      await pickCurrency(tester, 'SAR');
      expect(labels(tester), ['نقدًا', 'محفظة الراجحي']);
    });

    testWidgets('starting on USD, the SAR wallet is not even listed',
        (tester) async {
      final fixture = await BookFixture.create(seed: false);
      addTearDown(fixture.dispose);
      final account = await _mohammed(fixture);
      final wallet = await rajhi(fixture);

      await openForm(tester, fixture, account, filterCurrency: 'USD');
      expect(labels(tester), ['نقدًا']);
      expect(find.byKey(Key('payment-wallet-${wallet.id}')), findsNothing);
    });

    testWidgets('changing to a currency the chosen wallet lacks deselects it, '
        'asks for another and saves nothing until one is chosen',
        (tester) async {
      final fixture = await BookFixture.create(seed: false);
      addTearDown(fixture.dispose);
      final account = await _mohammed(fixture);
      final wallet = await rajhi(fixture);
      final before = (await fixture.book.transactions.matchTotals(account.id))
          .fold<int>(0, (sum, line) => sum + line.transactionCount);

      await openForm(tester, fixture, account, filterCurrency: 'SAR');
      await tester.tap(find.byKey(Key('payment-wallet-${wallet.id}')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(Key('payment-wallet-${wallet.id}')))
            .selected,
        isTrue,
      );

      await pickCurrency(tester, 'USD');
      // The wallet is gone from the list and nothing is selected any more.
      expect(find.byKey(Key('payment-wallet-${wallet.id}')), findsNothing);
      expect(find.byKey(const Key('tx-wallet-effect')), findsNothing);
      final hint = tester.widget<Text>(find.byKey(const Key('tx-payment-hint')));
      expect(hint.data, allOf(contains('محفظة الراجحي'), contains('USD')));

      // Saving is refused with the reason; nothing reaches the book.
      await tester.enterText(find.byKey(const Key('tx-amount')), '5');
      await tapSave(tester);
      expect(find.text('اختر وسيلة دفع تدعم عملة USD.'), findsOneWidget);
      final after = (await fixture.book.transactions.matchTotals(account.id))
          .fold<int>(0, (sum, line) => sum + line.transactionCount);
      expect(after, before);

      // Choosing a valid one (نقدًا) lets it save, in USD, from that wallet.
      await tester.dragUntilVisible(
        find.byKey(Key('payment-wallet-${(await fixture.ensureMainWallet()).id}')),
        find.byType(ListView),
        const Offset(0, 300),
        maxIteration: 50,
      );
      await tester.tap(
        find.byKey(Key('payment-wallet-${(await fixture.ensureMainWallet()).id}')),
      );
      await tester.pumpAndSettle();
      await tapSave(tester);
      final saved = (await fixture.book.repository.transactionPage(
        account.id,
        filter: const BookTransactionFilter(currencyCode: 'USD'),
        newestFirst: true,
        limit: 1,
      )).items.first;
      expect(saved.amountMinor, 500);
      expect(saved.walletId, (await fixture.ensureMainWallet()).id);
      // The SAR wallet was never touched and gained no currency.
      expect(await held(fixture, wallet.id), ['SAR']);
    });

    testWidgets('editing a SAR transaction into USD does the same and leaves '
        'the transaction as it was', (tester) async {
      final fixture = await BookFixture.create(seed: false);
      addTearDown(fixture.dispose);
      final account = await _mohammed(fixture);
      final wallet = await rajhi(fixture);
      final row = await fixture.book.transactions.create(
        BookTransactionDraft(
          accountId: account.id,
          currencyCode: 'SAR',
          type: EntryType.debit,
          amountMinor: 700,
          date: '2025-02-01',
          walletId: wallet.id,
        ),
      );

      await openForm(tester, fixture, account, transaction: row);
      expect(labels(tester), contains('محفظة الراجحي'));
      await pickCurrency(tester, 'USD');
      expect(labels(tester), ['نقدًا']);
      expect(find.byKey(const Key('tx-payment-hint')), findsOneWidget);
      await tapSave(tester);

      expect(find.text('اختر وسيلة دفع تدعم عملة USD.'), findsOneWidget);
      final unchanged = (await fixture.book.transactions.find(row.id))!;
      expect(unchanged.currencyCode, 'SAR');
      expect(unchanged.walletId, wallet.id);
      expect(await held(fixture, wallet.id), ['SAR']);

      // Back to SAR the wallet is valid again, but must be picked again.
      await pickCurrency(tester, 'SAR');
      expect(labels(tester), contains('محفظة الراجحي'));
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(Key('payment-wallet-${wallet.id}')))
            .selected,
        isFalse,
      );
    });

    testWidgets('the form never adds a currency to a wallet', (tester) async {
      final fixture = await BookFixture.create(seed: false);
      addTearDown(fixture.dispose);
      final account = await _mohammed(fixture);
      final wallet = await rajhi(fixture);
      final main = await fixture.ensureMainWallet();
      final mainBefore = await held(fixture, main.id);

      // Open, browse every currency, save a SAR payment from the SAR wallet.
      await openForm(tester, fixture, account, filterCurrency: 'SAR');
      for (final code in ['USD', 'YER', 'SAR']) {
        await pickCurrency(tester, code);
      }
      await tester.tap(find.byKey(Key('payment-wallet-${wallet.id}')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('tx-amount')), '10');
      await tapSave(tester);

      expect(await held(fixture, wallet.id), ['SAR']);
      expect(await held(fixture, main.id), mainBefore);
    });

    testWidgets('after adding USD to the wallet explicitly, it is offered for '
        'USD transactions', (tester) async {
      final fixture = await BookFixture.create(seed: false);
      addTearDown(fixture.dispose);
      final account = await _mohammed(fixture);
      final wallet = await rajhi(fixture);

      await openForm(tester, fixture, account, filterCurrency: 'USD');
      expect(labels(tester), ['نقدًا']);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      // The explicit action, on the wallet itself.
      await fixture.book.wallets.update(
        wallet.id,
        const WalletDraft(
          name: 'محفظة الراجحي',
          openings: [
            WalletOpeningDraft(currencyCode: 'SAR'),
            WalletOpeningDraft(currencyCode: 'USD'),
          ],
        ),
      );

      await openForm(tester, fixture, account, filterCurrency: 'USD');
      expect(labels(tester), ['نقدًا', 'محفظة الراجحي']);
    });

    testWidgets('a main wallet without the currency is explained and offers '
        'the explicit way to add it — never a side effect', (tester) async {
      final fixture = await BookFixture.create(seed: false);
      addTearDown(fixture.dispose);
      // A real device: «نقدًا» holds just the base currency.
      final main = await fixture.ensureMainWallet(currencies: ['YER']);
      final account = await fixture.book.accounts.create(
        BookAccountDraft(categoryId: fixture.category.id, name: 'محمد خالد'),
      );
      await fixture.book.transactions.create(
        BookTransactionDraft(
          accountId: account.id,
          currencyCode: 'YER',
          type: EntryType.debit,
          amountMinor: 1000,
          date: '2025-01-01',
          walletId: main.id,
        ),
      );

      await openForm(tester, fixture, account);
      // YER (the account's only currency): «نقدًا» is there.
      expect(labels(tester), ['نقدًا']);
      expect(find.byKey(const Key('tx-add-currency-to-main')), findsNothing);

      await pickCurrency(tester, 'SAR');
      expect(labels(tester), isEmpty);
      expect(find.byKey(const Key('tx-main-missing-currency')), findsOneWidget);
      final hint = tester.widget<Text>(find.byKey(const Key('tx-payment-hint')));
      expect(hint.data, contains('SAR'));
      // Nothing was added by looking at it.
      expect(await held(fixture, main.id), ['YER']);

      // The shortcut opens the wallet's own screen…
      await tester.ensureVisible(find.byKey(const Key('tx-add-currency-to-main')));
      await tester.tap(find.byKey(const Key('tx-add-currency-to-main')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('wallet-name')), findsOneWidget);
      expect(await held(fixture, main.id), ['YER'],
          reason: 'opening the wallet screen adds nothing either');

      // …where the currency is added explicitly (done here through the same
      // controller its form uses), and back on the transaction form «نقدًا»
      // is now offered and picked.
      await fixture.book.wallets.update(
        main.id,
        const WalletDraft(
          name: 'الصندوق الرئيسي',
          openings: [
            WalletOpeningDraft(currencyCode: 'YER'),
            WalletOpeningDraft(currencyCode: 'SAR'),
          ],
        ),
      );
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(labels(tester), ['نقدًا']);
      expect(find.byKey(const Key('tx-main-missing-currency')), findsNothing);
      expect(
        tester.widget<ChoiceChip>(find.byKey(Key('payment-wallet-${main.id}'))).selected,
        isTrue,
      );
    });
  });

  group('the account form', () {
    /// «إضافة حساب جديد إلى التصنيف» from the category page.
    Future<void> openNew(WidgetTester tester, BookFixture fixture) async {
      await pumpBookPage(
        tester,
        BookCategoryPage(book: fixture.book, categoryId: fixture.category.id),
        size: _tall,
      );
      await tester.tap(find.byKey(const Key('add-account-button')));
      await tester.pumpAndSettle();
    }

    testWidgets('has no currency field: any currency can be used later',
        (tester) async {
      final fixture = await BookFixture.create(seed: false);
      addTearDown(fixture.dispose);
      await openNew(tester, fixture);

      expect(find.byKey(const Key('account-currency')), findsNothing);
      expect(find.byKey(const Key('account-openings-hint')), findsOneWidget);
      expect(find.byKey(const Key('opening-row-0')), findsNothing);

      // Saved with just a name: the account exists with no currency at all.
      await tester.enterText(find.byKey(const Key('account-name')), 'محمد خالد');
      await tester.ensureVisible(find.byKey(const Key('save-button')));
      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();
      final saved = (await fixture.book.accounts.summaries()).single;
      expect(saved.account.name, 'محمد خالد');
      expect(saved.currencies, isEmpty);
      expect(await fixture.book.accounts.balances(saved.account.id), isEmpty);
    });

    testWidgets('takes an opening balance per currency, each with its own side',
        (tester) async {
      final fixture = await BookFixture.create(seed: false);
      addTearDown(fixture.dispose);
      await openNew(tester, fixture);
      await tester.enterText(find.byKey(const Key('account-name')), 'محمد خالد');

      // First row: the base currency (SAR in the test harness), credit 300.
      await tester.ensureVisible(find.byKey(const Key('add-opening')));
      await tester.tap(find.byKey(const Key('add-opening')));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byKey(const Key('opening-type-0')),
        matching: find.text('دائن'),
      ));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('opening-amount-0')), '300');

      // Second row: another currency, debit.
      await tester.ensureVisible(find.byKey(const Key('add-opening')));
      await tester.tap(find.byKey(const Key('add-opening')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('opening-currency-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ريال يمني (YER)').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('opening-amount-1')), '50000');

      await tester.ensureVisible(find.byKey(const Key('save-button')));
      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();

      final saved = (await fixture.book.accounts.summaries()).single;
      final openings = {
        for (final balance in await fixture.book.accounts.balances(
          saved.account.id,
        ))
          balance.currencyCode: balance,
      };
      expect(openings.keys, unorderedEquals(['SAR', 'YER']));
      expect(openings['SAR']!.openingMinor, 30000);
      expect(openings['SAR']!.openingType, OpeningType.credit);
      expect(openings['YER']!.openingMinor, 50000);
      expect(openings['YER']!.openingType, OpeningType.debit);
      expect(saved.totalsOf('SAR')!.netMinor, -30000);
      expect(saved.totalsOf('YER')!.netMinor, 50000);
    });

    testWidgets('editing shows the existing openings and removing one resets it',
        (tester) async {
      final fixture = await BookFixture.create(seed: false);
      addTearDown(fixture.dispose);
      final account = await _mohammed(fixture);
      await _openAccount(tester, fixture, account);
      await tester.tap(find.byKey(const Key('statement-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('تعديل الحساب'));
      await tester.pumpAndSettle();

      // Only SAR had an opening balance.
      expect(find.byKey(const Key('opening-row-0')), findsOneWidget);
      expect(find.byKey(const Key('opening-row-1')), findsNothing);
      expect(find.text('300.00'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('opening-remove-0')));
      await tester.tap(find.byKey(const Key('opening-remove-0')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('save-button')));
      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();

      final summary = (await fixture.book.accounts.summary(account.id))!;
      // SAR keeps its transaction, but its opening is now zero.
      expect(summary.totalsOf('SAR')!.openingMinor, 0);
      expect(summary.totalsOf('SAR')!.netMinor, 10000);
      // Every other currency is untouched.
      expect(summary.totalsOf('YER')!.netMinor, 25000);
    });
  });

  group('lists and reports', () {
    testWidgets('the category page shows every currency of an account',
        (tester) async {
      final fixture = await BookFixture.create(seed: false);
      addTearDown(fixture.dispose);
      final account = await _mohammed(fixture);
      await pumpBookPage(
        tester,
        BookCategoryPage(book: fixture.book, categoryId: fixture.category.id),
        size: _tall,
      );

      final card = find.byKey(Key('account-${account.id}'));
      expect(card, findsOneWidget);
      for (final code in ['YER', 'SAR', 'USD']) {
        expect(
          find.descendant(of: card, matching: find.byKey(Key('balance-line-$code'))),
          findsOneWidget,
          reason: code,
        );
      }
      // The side chips count an account in each side it has a balance on.
      expect(find.text('مدين (1)'), findsOneWidget);
      expect(find.text('دائن (1)'), findsOneWidget);

      // Searching a currency code finds the account through any of its currencies.
      await tester.tap(find.byKey(const Key('category-search')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('account-search')), 'usd');
      await tester.pumpAndSettle();
      expect(card, findsOneWidget);
      await tester.enterText(find.byKey(const Key('account-search')), 'kwd');
      await tester.pumpAndSettle();
      expect(card, findsNothing);
    });

    testWidgets('an account with no balance yet does not break the category '
        'page', (tester) async {
      final fixture = await BookFixture.create(seed: false);
      addTearDown(fixture.dispose);
      await fixture.book.accounts.create(
        BookAccountDraft(categoryId: fixture.category.id, name: 'جديد'),
      );
      await pumpBookPage(
        tester,
        BookCategoryPage(book: fixture.book, categoryId: fixture.category.id),
        size: _tall,
      );

      expect(find.text('جديد'), findsOneWidget);
      expect(find.byKey(const Key('balance-lines-empty')), findsOneWidget);
      expect(find.byKey(const Key('category-summary')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the archive lists every balance of an archived account',
        (tester) async {
      final fixture = await BookFixture.create(seed: false);
      addTearDown(fixture.dispose);
      final account = await _mohammed(fixture);
      await fixture.book.accounts.setStatus(account.id, BookAccountStatus.archived);
      await pumpBookPage(
        tester,
        BookArchivePage(book: fixture.book),
        size: _tall,
      );

      final subtitle = find.textContaining('YER');
      expect(subtitle, findsWidgets);
      final text = _textOf(tester, find.byKey(Key('archive-account-${account.id}')));
      expect(text, allOf(contains('25,000'), contains('200.00'), contains('20.00')));
    });

    testWidgets('the statement options offer a currency and build just that '
        'currency\'s statement', (tester) async {
      final fixture = await BookFixture.create(seed: false);
      addTearDown(fixture.dispose);
      final account = await _mohammed(fixture);
      await pumpBookPage(
        tester,
        AccountStatementOptionsPage(book: fixture.book, account: account),
        size: _tall,
      );

      expect(find.byKey(const Key('account-report-currency-كل العملات')), findsOneWidget);
      for (final code in ['SAR', 'USD', 'YER']) {
        expect(find.byKey(Key('account-report-currency-$code')), findsOneWidget);
      }
      await tester.tap(find.byKey(const Key('account-report-currency-SAR')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('عرض الكشف'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('report-view')), findsOneWidget);
      expect(find.textContaining('SAR'), findsWidgets);
      expect(find.textContaining('حركة SAR'), findsWidgets);
      expect(find.textContaining('حركة YER'), findsNothing);
      expect(find.textContaining('حركة USD'), findsNothing);
    });

    testWidgets('a single-currency account\'s options have no currency choice',
        (tester) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      await pumpBookPage(
        tester,
        AccountStatementOptionsPage(book: fixture.book, account: fixture.ali),
        size: _tall,
      );
      expect(find.byKey(const Key('account-report-currency-كل العملات')), findsNothing);
    });
  });
}
