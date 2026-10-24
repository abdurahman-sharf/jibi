import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/core/database/app_database.dart';
import 'package:jibi/core/database/sqlite_book_repository.dart';
import 'package:jibi/core/errors/app_exception.dart';
import 'package:jibi/core/models/models.dart';
import 'package:jibi/core/repositories/book_repository.dart';
import 'package:jibi/features/book/book.dart';
import 'package:jibi/features/wallets/wallets.dart';
import '../../support/book_wallets.dart';
import '../../support/test_currencies.dart';

/// One account, several currencies (schema v14): «محمد خالد» is ONE account
/// with an independent balance per currency. Everything runs on both
/// repositories (the in-memory double and a real SQLite database), because the
/// rules live in the controllers and must behave identically on both.
final class _Harness {
  _Harness(this.repository, this.dispose);

  final BookRepository repository;
  final Future<void> Function() dispose;
}

Future<_Harness> _openMemory() async {
  final repository = InMemoryBookRepository();
  return _Harness(repository, repository.dispose);
}

Future<_Harness> _openSqlite() async {
  final database = AppDatabase(path: inMemoryDatabasePath);
  final repository = SqliteBookRepository(database);
  return _Harness(repository, () async {
    await repository.dispose();
    await database.close();
  });
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  _suite('in-memory repository', _openMemory);
  _suite('sqlite repository', _openSqlite);
}

void _suite(String name, Future<_Harness> Function() open) {
  group(name, () {
    late _Harness harness;
    late CategoriesController categories;
    late BookAccountsController accounts;
    late TransactionsController transactions;
    late WalletsController wallets;
    var sequence = 0;
    var tick = DateTime.utc(2099, 1, 1);

    setUp(() async {
      sequence = 0;
      tick = DateTime.utc(2099, 1, 1);
      harness = await open();
      await seedMainWallet(harness.repository);
      final currencies = testCurrencyRegistry();
      String newId() => 'id-${++sequence}';
      DateTime clock() => tick = tick.add(const Duration(seconds: 1));
      categories = CategoriesController(
        repository: harness.repository,
        newId: newId,
        clock: clock,
      );
      accounts = BookAccountsController(
        repository: harness.repository,
        currencies: currencies,
        newId: newId,
        clock: clock,
      );
      transactions = TransactionsController(
        repository: harness.repository,
        currencies: currencies,
        newId: newId,
        clock: clock,
      );
      wallets = WalletsController(
        repository: harness.repository,
        currencies: currencies,
        newId: newId,
        clock: clock,
      );
    });

    tearDown(() => harness.dispose());

    Future<BookCategory> category([String name = 'حسابات اليمن']) =>
        categories.create(BookCategoryDraft(name: name));

    /// «محمد خالد»: one account, no currency chosen up front.
    Future<BookAccount> mohammed({
      List<BookAccountOpeningDraft>? openings,
      BookCategory? inCategory,
      String name = 'محمد خالد',
    }) async => accounts.create(
      BookAccountDraft(
        categoryId: (inCategory ?? await category()).id,
        name: name,
        openings: openings,
      ),
    );

    Future<BookTransaction> tx(
      BookAccount account,
      String currency,
      EntryType type,
      int amount,
      String date, {
      String? walletId,
      String time = '00:00',
    }) => transactions.create(
      BookTransactionDraft(
        accountId: account.id,
        currencyCode: currency,
        type: type,
        amountMinor: amount,
        date: date,
        time: time,
        walletId: walletId ?? seededMainWalletId,
      ),
    );

    BookTransactionDraft draftOf(
      BookTransaction row, {
      String? currency,
      EntryType? type,
      int? amount,
      String? date,
      String? walletId,
    }) => BookTransactionDraft(
      accountId: row.accountId,
      currencyCode: currency ?? row.currencyCode,
      type: type ?? row.type,
      amountMinor: amount ?? row.amountMinor,
      date: date ?? row.date,
      time: row.time,
      walletId: walletId ?? row.walletId,
    );

    Future<List<BookTransaction>> ascending(
      BookAccount account, {
      String? currency,
    }) async => (await harness.repository.transactionPage(
      account.id,
      filter: BookTransactionFilter(currencyCode: currency),
      newestFirst: false,
      limit: 500,
    )).items;

    Future<AccountSummary> summary(BookAccount account) async =>
        (await harness.repository.accountSummary(account.id))!;

    Future<int> netOf(BookAccount account, String currency) async =>
        (await summary(account)).totalsOf(currency)?.netMinor ?? 0;

    Future<int> walletBalance(String walletId, String currency) async =>
        (await harness.repository.walletSummary(walletId))!.balanceOf(currency);

    Future<void> expectConsistent(BookAccount account) async => expect(
      await harness.repository.countBalanceMismatches(account.id),
      0,
      reason: 'every currency\'s stored balance_after must match its own '
          'recomputed running balance',
    );

    group('one account, one balance per currency', () {
      test('a YER transaction, then SAR, then USD — all on the same account',
          () async {
        final a = await mohammed();
        expect((await summary(a)).currencies, isEmpty);

        await tx(a, 'YER', EntryType.debit, 1000, '2025-01-01');
        expect((await summary(a)).currencyCodes, ['YER']);
        await tx(a, 'SAR', EntryType.debit, 100, '2025-01-02');
        expect((await summary(a)).currencyCodes, ['SAR', 'YER']);
        await tx(a, 'USD', EntryType.debit, 20, '2025-01-03');
        expect((await summary(a)).currencyCodes, ['SAR', 'USD', 'YER']);

        // Still ONE account: nothing was created per currency.
        expect((await accounts.summaries()).length, 1);
        expect((await harness.repository.accountBalancesOf(a.id)).length, 3);
      });

      test('every currency keeps a fully independent balance', () async {
        final a = await mohammed();
        await tx(a, 'YER', EntryType.debit, 50000, '2025-01-01');
        await tx(a, 'SAR', EntryType.credit, 300, '2025-01-02');
        await tx(a, 'USD', EntryType.debit, 20, '2025-01-03');
        await tx(a, 'YER', EntryType.credit, 25000, '2025-01-04');

        final s = await summary(a);
        expect(s.totalsOf('YER')!.netMinor, 25000);
        expect(s.totalsOf('YER')!.side, BalanceSide.debit);
        expect(s.totalsOf('SAR')!.netMinor, -300);
        expect(s.totalsOf('SAR')!.side, BalanceSide.credit);
        expect(s.totalsOf('USD')!.netMinor, 20);
        expect(s.totalsOf('USD')!.transactionCount, 1);
        expect(s.totalsOf('YER')!.transactionCount, 2);
        // A count across currencies is a count, never an amount.
        expect(s.transactionCount, 4);
        // There is no number that adds YER + SAR + USD anywhere.
        expect(
          s.currencies.map((line) => line.netMinor),
          isNot(contains(25000 - 300 + 20)),
        );
        await expectConsistent(a);
      });

      test('DEBIT and CREDIT work in each currency', () async {
        final a = await mohammed();
        for (final code in ['YER', 'SAR', 'USD']) {
          await tx(a, code, EntryType.debit, 1000, '2025-01-01');
          await tx(a, code, EntryType.credit, 400, '2025-01-02');
          await tx(a, code, EntryType.debit, 50, '2025-01-03');
        }
        for (final code in ['YER', 'SAR', 'USD']) {
          final line = (await summary(a)).totalsOf(code)!;
          expect(line.debitMinor, 1050, reason: code);
          expect(line.creditMinor, 400, reason: code);
          expect(line.netMinor, 650, reason: code);
        }
        await expectConsistent(a);
      });

      test('a different opening balance per currency, on either side', () async {
        final a = await mohammed(
          openings: const [
            BookAccountOpeningDraft(
              currencyCode: 'YER',
              openingMinor: 5000,
              openingType: OpeningType.debit,
            ),
            BookAccountOpeningDraft(
              currencyCode: 'SAR',
              openingMinor: 300,
              openingType: OpeningType.credit,
            ),
          ],
        );
        var s = await summary(a);
        expect(s.currencyCodes, ['SAR', 'YER']);
        expect(s.totalsOf('YER')!.netMinor, 5000);
        expect(s.totalsOf('SAR')!.netMinor, -300);
        expect(s.totalsOf('USD'), isNull, reason: 'USD was never used');

        // A running balance starts from ITS OWN currency's opening.
        final yer = await tx(a, 'YER', EntryType.debit, 1000, '2025-01-01');
        final sar = await tx(a, 'SAR', EntryType.debit, 100, '2025-01-01');
        final usd = await tx(a, 'USD', EntryType.debit, 20, '2025-01-01');
        expect(yer.balanceAfter, 6000);
        expect(sar.balanceAfter, -200);
        expect(usd.balanceAfter, 20, reason: 'an unused currency opens at zero');
        s = await summary(a);
        expect(s.totalsOf('USD')!.openingMinor, 0);
        await expectConsistent(a);
      });

      test('an account with only an opening balance shows just that currency',
          () async {
        final a = await mohammed(
          openings: const [
            BookAccountOpeningDraft(
              currencyCode: 'USD',
              openingMinor: 20,
              openingType: OpeningType.debit,
            ),
            // Declared but empty: never shown.
            BookAccountOpeningDraft(currencyCode: 'YER'),
          ],
        );
        expect((await summary(a)).currencyCodes, ['USD']);
      });
    });

    group('balance_after is per (account, currency)', () {
      test('interleaved currencies never disturb each other', () async {
        final a = await mohammed();
        final y1 = await tx(a, 'YER', EntryType.debit, 100, '2025-01-01');
        final s1 = await tx(a, 'SAR', EntryType.debit, 10, '2025-01-02');
        final y2 = await tx(a, 'YER', EntryType.debit, 200, '2025-01-03');
        final s2 = await tx(a, 'SAR', EntryType.credit, 4, '2025-01-04');

        expect(y1.balanceAfter, 100);
        expect(y2.balanceAfter, 300);
        expect(s1.balanceAfter, 10);
        expect(s2.balanceAfter, 6);
        expect((await ascending(a, currency: 'YER')).map((r) => r.balanceAfter), [
          100,
          300,
        ]);
        expect((await ascending(a, currency: 'SAR')).map((r) => r.balanceAfter), [
          10,
          6,
        ]);
      });

      test('a back-dated YER row rebalances YER only', () async {
        final a = await mohammed();
        await tx(a, 'YER', EntryType.debit, 100, '2025-01-10');
        await tx(a, 'SAR', EntryType.debit, 7, '2025-01-11');
        await tx(a, 'YER', EntryType.debit, 300, '2025-01-20');
        final sarBefore = await ascending(a, currency: 'SAR');

        await tx(a, 'YER', EntryType.credit, 50, '2025-01-15');

        expect((await ascending(a, currency: 'YER')).map((r) => r.balanceAfter), [
          100,
          50,
          350,
        ]);
        expect(
          (await ascending(a, currency: 'SAR')).map((r) => r.balanceAfter),
          sarBefore.map((r) => r.balanceAfter),
        );
        await expectConsistent(a);
      });

      test('editing the amount rebalances the later rows of that currency',
          () async {
        final a = await mohammed();
        final first = await tx(a, 'YER', EntryType.debit, 100, '2025-01-10');
        await tx(a, 'SAR', EntryType.debit, 7, '2025-01-11');
        await tx(a, 'YER', EntryType.debit, 300, '2025-01-20');

        await transactions.update(first.id, draftOf(first, amount: 400));

        expect((await ascending(a, currency: 'YER')).map((r) => r.balanceAfter), [
          400,
          700,
        ]);
        expect((await ascending(a, currency: 'SAR')).single.balanceAfter, 7);
        expect(await netOf(a, 'YER'), 700);
        expect(await netOf(a, 'SAR'), 7);
        await expectConsistent(a);
      });

      test('flipping DEBIT to CREDIT changes only that currency', () async {
        final a = await mohammed();
        final row = await tx(a, 'YER', EntryType.debit, 500, '2025-01-10');
        await tx(a, 'SAR', EntryType.debit, 9, '2025-01-11');

        await transactions.update(row.id, draftOf(row, type: EntryType.credit));

        expect(await netOf(a, 'YER'), -500);
        expect(await netOf(a, 'SAR'), 9);
        expect(
          (await ascending(a, currency: 'YER')).single.balanceAfter,
          -500,
        );
        await expectConsistent(a);
      });

      test('deleting and undoing a transaction touches only its currency',
          () async {
        final a = await mohammed();
        await tx(a, 'YER', EntryType.debit, 100, '2025-01-10');
        final middle = await tx(a, 'YER', EntryType.debit, 200, '2025-01-11');
        await tx(a, 'YER', EntryType.debit, 300, '2025-01-12');
        await tx(a, 'SAR', EntryType.debit, 5, '2025-01-11');

        await transactions.delete(middle.id);
        expect((await ascending(a, currency: 'YER')).map((r) => r.balanceAfter), [
          100,
          400,
        ]);
        expect(await netOf(a, 'YER'), 400);
        expect(await netOf(a, 'SAR'), 5);

        await transactions.restore(middle.id);
        expect((await ascending(a, currency: 'YER')).map((r) => r.balanceAfter), [
          100,
          300,
          600,
        ]);
        expect(await netOf(a, 'YER'), 600);
        expect(await netOf(a, 'SAR'), 5);
        await expectConsistent(a);
      });

      test('changing a transaction\'s currency rebalances both currencies',
          () async {
        final a = await mohammed();
        await tx(a, 'YER', EntryType.debit, 100, '2025-01-10');
        final moving = await tx(a, 'YER', EntryType.debit, 200, '2025-01-11');
        await tx(a, 'YER', EntryType.debit, 300, '2025-01-12');
        await tx(a, 'SAR', EntryType.debit, 5, '2025-01-09');
        await tx(a, 'SAR', EntryType.debit, 6, '2025-01-13');

        final moved = await transactions.update(
          moving.id,
          draftOf(moving, currency: 'SAR', amount: 20),
        );

        expect(moved.currencyCode, 'SAR');
        expect((await ascending(a, currency: 'YER')).map((r) => r.balanceAfter), [
          100,
          400,
        ]);
        expect((await ascending(a, currency: 'SAR')).map((r) => r.balanceAfter), [
          5,
          25,
          31,
        ]);
        expect(await netOf(a, 'YER'), 400);
        expect(await netOf(a, 'SAR'), 31);
        await expectConsistent(a);
      });

      test('moving the last transaction of a currency away hides that currency',
          () async {
        final a = await mohammed();
        final only = await tx(a, 'USD', EntryType.debit, 20, '2025-01-10');
        await tx(a, 'YER', EntryType.debit, 1, '2025-01-10');
        expect((await summary(a)).currencyCodes, ['USD', 'YER']);

        await transactions.update(only.id, draftOf(only, currency: 'YER'));

        // Nothing left in USD: it is no longer one of the account's balances.
        expect((await summary(a)).currencyCodes, ['YER']);
        expect(await netOf(a, 'YER'), 21);
      });
    });

    group('the payment wallet follows the transaction\'s currency', () {
      test('a SAR transaction paid from the main wallet moves its SAR only',
          () async {
        final a = await mohammed();
        await tx(a, 'SAR', EntryType.debit, 100, '2025-01-10');

        expect(await walletBalance(seededMainWalletId, 'SAR'), -100);
        expect(await walletBalance(seededMainWalletId, 'YER'), 0);
        expect(await walletBalance(seededMainWalletId, 'USD'), 0);
        expect(await netOf(a, 'SAR'), 100);
        expect(await netOf(a, 'YER'), 0);
      });

      test('a YER transaction from another wallet moves that wallet\'s YER only',
          () async {
        final rajhi = await wallets.create(
          WalletDraft.single(name: 'محفظة الراجحي', currencyCode: 'YER'),
        );
        final a = await mohammed();
        await tx(a, 'YER', EntryType.credit, 700, '2025-01-10', walletId: rajhi.id);

        expect(await walletBalance(rajhi.id, 'YER'), 700);
        expect(await walletBalance(rajhi.id, 'SAR'), 0);
        expect(await walletBalance(seededMainWalletId, 'YER'), 0);
      });

      test('there is exactly one linked wallet movement per event, in the '
          'transaction\'s currency', () async {
        final a = await mohammed();
        final row = await tx(a, 'SAR', EntryType.debit, 100, '2025-01-10');
        final link = await harness.repository.write(
          (writer) => writer.walletTransactionForBookTransaction(row.id),
        );
        expect(link, isNotNull);
        expect(link!.currencyCode, 'SAR');
        expect(link.amountMinor, 100);
        expect(link.type, WalletTransactionType.linked);
        expect(
          (await harness.repository.walletSummary(seededMainWalletId))!
              .transactionCount,
          1,
        );
      });

      test(
        'changing the currency reverses the old wallet movement and applies '
        'the new one',
        () async {
          final a = await mohammed();
          final row = await tx(a, 'YER', EntryType.debit, 500, '2025-01-10');
          expect(await walletBalance(seededMainWalletId, 'YER'), -500);

          await transactions.update(
            row.id,
            draftOf(row, currency: 'SAR', amount: 30),
          );

          expect(await walletBalance(seededMainWalletId, 'YER'), 0);
          expect(await walletBalance(seededMainWalletId, 'SAR'), -30);
          expect(
            (await harness.repository.walletSummary(seededMainWalletId))!
                .transactionCount,
            1,
            reason: 'the old movement is gone, not duplicated',
          );
        },
      );

      test('changing the wallet moves the effect between the two wallets',
          () async {
        final rajhi = await wallets.create(
          WalletDraft.single(name: 'محفظة الراجحي', currencyCode: 'SAR'),
        );
        final a = await mohammed();
        final row = await tx(a, 'SAR', EntryType.debit, 100, '2025-01-10');
        expect(await walletBalance(seededMainWalletId, 'SAR'), -100);

        await transactions.update(row.id, draftOf(row, walletId: rajhi.id));

        expect(await walletBalance(seededMainWalletId, 'SAR'), 0);
        expect(await walletBalance(rajhi.id, 'SAR'), -100);
      });

      test('flipping the type flips the wallet effect in that currency', () async {
        final a = await mohammed();
        final row = await tx(a, 'USD', EntryType.debit, 20, '2025-01-10');
        expect(await walletBalance(seededMainWalletId, 'USD'), -20);

        await transactions.update(row.id, draftOf(row, type: EntryType.credit));

        expect(await walletBalance(seededMainWalletId, 'USD'), 20);
      });

      test('deleting and undoing reverses and restores the wallet in its currency',
          () async {
        final a = await mohammed();
        final sar = await tx(a, 'SAR', EntryType.debit, 100, '2025-01-10');
        await tx(a, 'YER', EntryType.debit, 5000, '2025-01-11');

        await transactions.delete(sar.id);
        expect(await walletBalance(seededMainWalletId, 'SAR'), 0);
        expect(await walletBalance(seededMainWalletId, 'YER'), -5000);

        await transactions.restore(sar.id);
        expect(await walletBalance(seededMainWalletId, 'SAR'), -100);
        expect(await walletBalance(seededMainWalletId, 'YER'), -5000);
      });

      test(
        'a failing wallet side rolls the whole edit back — currency and balances '
        'stay as they were',
        () async {
          final closed = await wallets.create(
            WalletDraft.single(name: 'محفظة مقفلة', currencyCode: 'SAR'),
          );
          await wallets.setStatus(closed.id, WalletStatus.archived);
          final a = await mohammed();
          final row = await tx(a, 'YER', EntryType.debit, 500, '2025-01-10');
          await tx(a, 'YER', EntryType.debit, 100, '2025-01-11');

          await expectLater(
            transactions.update(
              row.id,
              draftOf(row, currency: 'SAR', walletId: closed.id),
            ),
            throwsA(isA<ConflictException>()),
          );

          final unchanged = (await transactions.find(row.id))!;
          expect(unchanged.currencyCode, 'YER');
          expect(unchanged.walletId, seededMainWalletId);
          expect(await netOf(a, 'YER'), 600);
          expect(await netOf(a, 'SAR'), 0);
          expect(await walletBalance(seededMainWalletId, 'YER'), -600);
          expect(await walletBalance(closed.id, 'SAR'), 0);
          await expectConsistent(a);
        },
      );
    });

    group('a wallet is a payment method only in a currency it already holds',
        () {
      /// «محفظة الراجحي»: holds SAR only.
      Future<Wallet> rajhi() => wallets.create(
        WalletDraft.single(name: 'محفظة الراجحي', currencyCode: 'SAR'),
      );

      Future<List<String>> held(String walletId) async => [
        for (final b in await harness.repository.walletBalancesOf(walletId))
          b.currencyCode,
      ];

      Matcher unsupported() => throwsA(
        isA<ValidationException>().having(
          (e) => e.code,
          'code',
          'wallet_currency_unsupported',
        ),
      );

      test('a SAR wallet takes a SAR transaction, refuses a USD one, and '
          'gains no USD balance', () async {
        final wallet = await rajhi();
        final a = await mohammed();

        await tx(a, 'SAR', EntryType.debit, 10000, '2025-01-10', walletId: wallet.id);
        expect(await walletBalance(wallet.id, 'SAR'), -10000);

        await expectLater(
          tx(a, 'USD', EntryType.debit, 2000, '2025-01-11', walletId: wallet.id),
          unsupported(),
        );
        // Nothing was saved on either side and no currency was added.
        expect(await ascending(a, currency: 'USD'), isEmpty);
        expect((await summary(a)).currencyCodes, ['SAR']);
        expect(await held(wallet.id), ['SAR']);
        expect(await walletBalance(wallet.id, 'USD'), 0);
      });

      test('the refusal names the wallet and the currency', () async {
        final wallet = await rajhi();
        final a = await mohammed();
        await expectLater(
          tx(a, 'USD', EntryType.debit, 1, '2025-01-11', walletId: wallet.id),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.userMessage,
              'message',
              allOf(contains('محفظة الراجحي'), contains('USD')),
            ),
          ),
        );
      });

      test('a refused transaction consumes no number and no balance row',
          () async {
        final wallet = await rajhi();
        final a = await mohammed();
        await expectLater(
          tx(a, 'USD', EntryType.debit, 1, '2025-01-11', walletId: wallet.id),
          unsupported(),
        );
        expect(
          await harness.repository.accountBalancesOf(a.id),
          isEmpty,
          reason: 'not even the account gained a USD row',
        );
        final first = await tx(a, 'SAR', EntryType.debit, 1, '2025-01-12',
            walletId: wallet.id);
        expect(first.number, 'TX-000001');
      });

      test('changing a SAR transaction to USD is refused when its wallet holds '
          'only SAR — nothing changes', () async {
        final wallet = await rajhi();
        final a = await mohammed();
        final row = await tx(a, 'SAR', EntryType.debit, 10000, '2025-01-10',
            walletId: wallet.id);

        await expectLater(
          transactions.update(row.id, draftOf(row, currency: 'USD')),
          unsupported(),
        );

        final unchanged = (await transactions.find(row.id))!;
        expect(unchanged.currencyCode, 'SAR');
        expect(unchanged.walletId, wallet.id);
        expect(await netOf(a, 'SAR'), 10000);
        expect(await netOf(a, 'USD'), 0);
        expect(await walletBalance(wallet.id, 'SAR'), -10000);
        expect(await held(wallet.id), ['SAR']);
        await expectConsistent(a);
      });

      test('moving a transaction to a wallet without its currency is refused',
          () async {
        final wallet = await rajhi();
        final a = await mohammed();
        final row = await tx(a, 'YER', EntryType.debit, 500, '2025-01-10');

        await expectLater(
          transactions.update(row.id, draftOf(row, walletId: wallet.id)),
          unsupported(),
        );

        expect((await transactions.find(row.id))!.walletId, seededMainWalletId);
        expect(await walletBalance(seededMainWalletId, 'YER'), -500);
        expect(await held(wallet.id), ['SAR']);
      });

      test('editing amount or date of a paid transaction never touches the '
          'wallet\'s currencies', () async {
        final wallet = await rajhi();
        final a = await mohammed();
        final row = await tx(a, 'SAR', EntryType.debit, 10000, '2025-01-10',
            walletId: wallet.id);

        await transactions.update(
          row.id,
          draftOf(row, amount: 12500, date: '2025-01-15'),
        );

        expect(await walletBalance(wallet.id, 'SAR'), -12500);
        expect(await held(wallet.id), ['SAR']);
      });

      test('after adding USD to the wallet explicitly, USD transactions are '
          'accepted', () async {
        final wallet = await rajhi();
        final a = await mohammed();
        await expectLater(
          tx(a, 'USD', EntryType.debit, 2000, '2025-01-11', walletId: wallet.id),
          unsupported(),
        );

        // The explicit action, on the wallet itself (its own form does this).
        await wallets.update(
          wallet.id,
          const WalletDraft(
            name: 'محفظة الراجحي',
            openings: [
              WalletOpeningDraft(currencyCode: 'SAR'),
              WalletOpeningDraft(currencyCode: 'USD', openingMinor: 5000),
            ],
          ),
        );
        expect(await held(wallet.id), ['SAR', 'USD']);

        await tx(a, 'USD', EntryType.debit, 2000, '2025-01-12', walletId: wallet.id);
        // The opening the user gave counts; the other currency is untouched.
        expect(await walletBalance(wallet.id, 'USD'), 5000 - 2000);
        expect(await walletBalance(wallet.id, 'SAR'), 0);
        expect(await netOf(a, 'USD'), 2000);
      });

      test('a wallet keeps a currency that its transactions use', () async {
        final wallet = await rajhi();
        final a = await mohammed();
        await tx(a, 'SAR', EntryType.debit, 10000, '2025-01-10', walletId: wallet.id);
        await expectLater(
          wallets.update(
            wallet.id,
            const WalletDraft(
              name: 'محفظة الراجحي',
              openings: [WalletOpeningDraft(currencyCode: 'USD')],
            ),
          ),
          throwsA(isA<ConflictException>()),
        );
        expect(await held(wallet.id), ['SAR']);
      });

      test('the main wallet follows the same rule and stays «نقدًا»', () async {
        // A main wallet that holds YER only, like a real device.
        final old = await harness.repository.walletSummaries();
        for (final summary in old) {
          await wallets.delete(summary.wallet.id);
        }
        final main = await wallets.create(
          WalletDraft.single(name: 'الصندوق الرئيسي', currencyCode: 'YER'),
        );
        await wallets.setMain(main.id);
        final a = await mohammed();

        await tx(a, 'YER', EntryType.debit, 500, '2025-01-10', walletId: main.id);
        await expectLater(
          tx(a, 'SAR', EntryType.debit, 100, '2025-01-11', walletId: main.id),
          unsupported(),
        );
        expect(await held(main.id), ['YER']);
        expect((await wallets.find(main.id))!.paymentLabel, 'نقدًا');

        // Adding SAR to the main wallet is an explicit action on the wallet.
        await wallets.update(
          main.id,
          const WalletDraft(
            name: 'الصندوق الرئيسي',
            openings: [
              WalletOpeningDraft(currencyCode: 'YER'),
              WalletOpeningDraft(currencyCode: 'SAR'),
            ],
          ),
        );
        await tx(a, 'SAR', EntryType.debit, 100, '2025-01-11', walletId: main.id);
        expect(await walletBalance(main.id, 'SAR'), -100);
        expect(await walletBalance(main.id, 'YER'), -500);
      });
    });

    group('accounts, categories and the financial position', () {
      test('category totals are per currency and add nothing across them',
          () async {
        final c = await category();
        final one = await mohammed(inCategory: c);
        final two = await mohammed(inCategory: c, name: 'علي أخي');
        await tx(one, 'YER', EntryType.debit, 1000, '2025-01-01');
        await tx(one, 'SAR', EntryType.credit, 40, '2025-01-01');
        await tx(two, 'YER', EntryType.debit, 500, '2025-01-01');
        await tx(two, 'USD', EntryType.debit, 20, '2025-01-01');

        final totals = (await harness.repository.categorySummaries())
            .single
            .totals;
        expect(totals.map((t) => t.currencyCode), ['SAR', 'USD', 'YER']);
        final yer = totals.firstWhere((t) => t.currencyCode == 'YER');
        expect(yer.debitMinor, 1500);
        expect(yer.creditMinor, 0);
        expect(yer.accountCount, 2, reason: 'both accounts use YER');
        final sar = totals.firstWhere((t) => t.currencyCode == 'SAR');
        expect(sar.creditMinor, 40);
        expect(sar.accountCount, 1);
        final usd = totals.firstWhere((t) => t.currencyCode == 'USD');
        expect(usd.debitMinor, 20);
      });

      test('the net position groups by the transaction currency', () async {
        final c = await category();
        final one = await mohammed(inCategory: c);
        final two = await mohammed(inCategory: c, name: 'علي أخي');
        await tx(one, 'YER', EntryType.debit, 1000, '2025-01-01');
        await tx(one, 'SAR', EntryType.debit, 30, '2025-01-01');
        await tx(two, 'SAR', EntryType.credit, 10, '2025-01-01');

        final position = await harness.repository.netPosition();
        expect(position.map((p) => p.currencyCode), ['SAR', 'YER']);
        final sar = position.firstWhere((p) => p.currencyCode == 'SAR');
        expect(sar.debitMinor, 30);
        expect(sar.creditMinor, 10);
        expect(sar.netMinor, 20);
        final yer = position.firstWhere((p) => p.currencyCode == 'YER');
        expect(yer.netMinor, 1000);
      });

      test('archived accounts and deleted rows stay out of every currency',
          () async {
        final c = await category();
        final live = await mohammed(inCategory: c);
        final old = await mohammed(inCategory: c, name: 'قديم');
        await tx(live, 'SAR', EntryType.debit, 10, '2025-01-01');
        final gone = await tx(live, 'USD', EntryType.debit, 5, '2025-01-01');
        await tx(old, 'YER', EntryType.debit, 900, '2025-01-01');
        await accounts.setStatus(old.id, BookAccountStatus.archived);
        await transactions.delete(gone.id);

        final position = await harness.repository.netPosition();
        expect(position.map((p) => p.currencyCode), ['SAR']);
      });

      test('the list of accounts carries every currency line of each account',
          () async {
        final one = await mohammed();
        await tx(one, 'YER', EntryType.debit, 50000, '2025-01-01');
        await tx(one, 'SAR', EntryType.credit, 300, '2025-01-01');
        await tx(one, 'USD', EntryType.debit, 20, '2025-01-01');

        final listed = (await accounts.summaries()).single;
        expect(listed.currencies.map((l) => '${l.currencyCode}:${l.netMinor}'), [
          'SAR:-300',
          'USD:20',
          'YER:50000',
        ]);
      });
    });

    group('the transaction list and its filters', () {
      test('filtering by one currency lists, counts and totals just that one',
          () async {
        final a = await mohammed();
        await tx(a, 'YER', EntryType.debit, 1000, '2025-01-01');
        await tx(a, 'SAR', EntryType.debit, 100, '2025-01-02');
        await tx(a, 'SAR', EntryType.credit, 30, '2025-01-03');
        await tx(a, 'USD', EntryType.debit, 20, '2025-01-04');

        expect((await ascending(a)).length, 4);
        expect((await ascending(a, currency: 'SAR')).length, 2);
        expect((await ascending(a, currency: 'usd')).length, 1);

        final all = await transactions.matchTotals(a.id);
        expect(all.map((l) => l.currencyCode), ['SAR', 'USD', 'YER']);
        final onlySar = await transactions.matchTotals(
          a.id,
          filter: const BookTransactionFilter(currencyCode: 'SAR'),
        );
        expect(onlySar.single.currencyCode, 'SAR');
        expect(onlySar.single.debitMinor, 100);
        expect(onlySar.single.creditMinor, 30);
        expect(onlySar.single.transactionCount, 2);
        expect(
          const BookTransactionFilter(currencyCode: 'SAR').isEmpty,
          isFalse,
        );
      });
    });

    group('editing the opening balances of an account', () {
      test('adding, changing and removing a currency\'s opening', () async {
        final c = await category();
        final a = await mohammed(
          inCategory: c,
          openings: const [
            BookAccountOpeningDraft(
              currencyCode: 'YER',
              openingMinor: 1000,
              openingType: OpeningType.debit,
            ),
          ],
        );
        await tx(a, 'YER', EntryType.debit, 100, '2025-01-01');
        await tx(a, 'SAR', EntryType.debit, 7, '2025-01-01');

        // Change YER, add USD, leave SAR out (it has a transaction: reset).
        await accounts.update(
          a.id,
          BookAccountDraft(
            categoryId: c.id,
            name: a.name,
            openings: const [
              BookAccountOpeningDraft(
                currencyCode: 'YER',
                openingMinor: 200,
                openingType: OpeningType.credit,
              ),
              BookAccountOpeningDraft(
                currencyCode: 'USD',
                openingMinor: 20,
                openingType: OpeningType.debit,
              ),
            ],
          ),
        );

        expect(await netOf(a, 'YER'), -100);
        expect(
          (await ascending(a, currency: 'YER')).single.balanceAfter,
          -100,
          reason: 'the running balance is reseeded from the new opening',
        );
        expect(await netOf(a, 'USD'), 20);
        expect(await netOf(a, 'SAR'), 7);
        expect((await summary(a)).totalsOf('SAR')!.openingMinor, 0);
        await expectConsistent(a);
      });

      test('an update without openings leaves them alone', () async {
        final c = await category();
        final a = await mohammed(
          inCategory: c,
          openings: const [
            BookAccountOpeningDraft(
              currencyCode: 'SAR',
              openingMinor: 300,
              openingType: OpeningType.credit,
            ),
          ],
        );
        await accounts.update(
          a.id,
          BookAccountDraft(categoryId: c.id, name: 'اسم جديد'),
        );
        expect(await netOf(a, 'SAR'), -300);
      });

      test('an unused currency\'s row disappears when its opening is removed',
          () async {
        final c = await category();
        final a = await mohammed(
          inCategory: c,
          openings: const [
            BookAccountOpeningDraft(
              currencyCode: 'USD',
              openingMinor: 20,
              openingType: OpeningType.debit,
            ),
          ],
        );
        await accounts.update(
          a.id,
          BookAccountDraft(
            categoryId: c.id,
            name: a.name,
            openings: const <BookAccountOpeningDraft>[],
          ),
        );
        expect(await harness.repository.accountBalancesOf(a.id), isEmpty);
      });

      test('rejects a repeated, unknown or inactive currency and bad amounts',
          () async {
        final c = await category();
        Future<BookAccount> create(List<BookAccountOpeningDraft> openings) =>
            accounts.create(
              BookAccountDraft(categoryId: c.id, name: 'x', openings: openings),
            );
        await expectLater(
          create(const [
            BookAccountOpeningDraft(currencyCode: 'YER'),
            BookAccountOpeningDraft(currencyCode: 'yer'),
          ]),
          throwsA(isA<ValidationException>()),
        );
        await expectLater(
          create(const [BookAccountOpeningDraft(currencyCode: 'XXX')]),
          throwsA(isA<ValidationException>()),
        );
        await expectLater(
          create(const [
            BookAccountOpeningDraft(currencyCode: 'YER', openingMinor: 5),
          ]),
          throwsA(isA<ValidationException>()),
        );
        await expectLater(
          create(const [
            BookAccountOpeningDraft(
              currencyCode: 'YER',
              openingMinor: -5,
              openingType: OpeningType.debit,
            ),
          ]),
          throwsA(isA<ValidationException>()),
        );
      });

      test('deleting an account removes all of its currency rows', () async {
        final a = await mohammed(
          openings: const [
            BookAccountOpeningDraft(
              currencyCode: 'SAR',
              openingMinor: 30,
              openingType: OpeningType.debit,
            ),
          ],
        );
        await tx(a, 'YER', EntryType.debit, 10, '2025-01-01');
        await accounts.delete(a.id);
        expect(await harness.repository.accountBalancesOf(a.id), isEmpty);
        expect(await accounts.find(a.id), isNull);
      });
    });

    group('a transaction always names a valid currency', () {
      test('an unknown currency is refused', () async {
        final a = await mohammed();
        await expectLater(
          tx(a, 'XXX', EntryType.debit, 1, '2025-01-01'),
          throwsA(isA<ValidationException>()),
        );
        expect(await ascending(a), isEmpty);
      });

      test('an audit entry names the currency of the transaction', () async {
        final a = await mohammed();
        final row = await tx(a, 'SAR', EntryType.debit, 100, '2025-01-01');
        await transactions.update(row.id, draftOf(row, currency: 'USD', amount: 25));
        final entries = (await harness.repository.auditPage(
          entity: BookAuditEntity.transaction,
          limit: 50,
        )).items;
        final created = entries.firstWhere((e) => e.action == 'created');
        expect(created.details, contains('SAR'));
        final changed = entries.firstWhere((e) => e.action == 'currency_changed');
        expect(changed.details, '100 SAR->25 USD');
        expect(created.currencyCode, 'USD',
            reason: 'the live row now carries its current currency');
      });
    });
  });
}
