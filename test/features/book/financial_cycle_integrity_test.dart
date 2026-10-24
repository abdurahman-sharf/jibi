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

/// End-to-end review of the accounts-book ↔ wallets financial cycle, across
/// more than one currency (YER and SAR in particular), for one multi-currency
/// account paid alternately from «نقدًا» and from another wallet.
///
/// This complements (does not replace) `book_contract_test.dart`,
/// `multi_currency_account_test.dart` and `wallet_contract_test.dart`: those
/// already cover most of these rules one at a time. This file walks the same
/// rules as one connected story per requirement, and adds the two checks that
/// were missing: a wallet-side `balance_after` integrity scan (mirroring
/// [BookRepository.countBalanceMismatches]) and a whole-wallet scan for
/// duplicate or orphaned `linked` movements.
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
    late BookServices book;

    setUp(() async {
      harness = await open();
      await seedMainWallet(harness.repository);
      book = BookServices(
        repository: harness.repository,
        currencies: testCurrencyRegistry(),
        defaultCurrencyCode: () => 'YER',
      );
    });

    tearDown(() => harness.dispose());

    // ---- shared helpers --------------------------------------------------

    Future<WalletTransaction?> linkOf(String bookTransactionId) =>
        harness.repository.write(
          (writer) => writer.walletTransactionForBookTransaction(bookTransactionId),
        );

    Future<int> walletBalance(String walletId, String code) async =>
        (await harness.repository.walletSummary(walletId))!.balanceOf(code);

    Future<int?> accountBalance(String accountId, String code) async =>
        (await harness.repository.accountSummary(accountId))!.totalsOf(code)?.netMinor;

    /// The one live currency-code the transaction moves in [accountId]'s
    /// statement, in ascending date order — `balance_after` as actually
    /// stored.
    Future<List<int>> balancesAfter(String accountId, String code) async {
      final page = await harness.repository.transactionPage(
        accountId,
        newestFirst: false,
        limit: 200,
      );
      return [
        for (final row in page.items)
          if (row.currencyCode == code) row.balanceAfter,
      ];
    }

    /// Requirement 12: a wallet-side equivalent of
    /// [BookRepository.countBalanceMismatches] — every wallet touched in this
    /// suite must have a `balance_after` that agrees with a recompute from its
    /// live movements.
    Future<void> expectWalletConsistent(String walletId) async {
      expect(
        await harness.repository.countWalletBalanceMismatches(walletId),
        0,
        reason: 'wallet $walletId has a stale balance_after',
      );
    }

    Future<void> expectAccountConsistent(String accountId) async {
      expect(
        await harness.repository.countBalanceMismatches(accountId),
        0,
        reason: 'account $accountId has a stale balance_after',
      );
    }

    /// Requirement 8: one [bookTransactionId] paid through [walletId] must
    /// have EXACTLY one live `linked` wallet movement, and it must agree on
    /// currency, amount and direction — never an orphan, never a duplicate.
    Future<void> expectExactLink(
      String bookTransactionId, {
      required String walletId,
      required String currencyCode,
      required int amountMinor,
      required WalletDirection direction,
    }) async {
      final link = await linkOf(bookTransactionId);
      expect(link, isNotNull, reason: 'missing linked wallet movement');
      expect(link!.isDeleted, isFalse);
      expect(link.walletId, walletId);
      expect(link.currencyCode, currencyCode);
      expect(link.amountMinor, amountMinor);
      expect(link.direction, direction);
      expect(link.type, WalletTransactionType.linked);
      // No duplicate: scanning every movement of the wallet finds exactly one
      // live `linked` row pointing at this transaction.
      final all = await harness.repository.write(
        (writer) => writer.allWalletTransactionsOf(walletId),
      );
      final matching = all.where(
        (row) =>
            !row.isDeleted &&
            row.type == WalletTransactionType.linked &&
            row.linkedBookTransactionId == bookTransactionId,
      );
      expect(matching, hasLength(1));
    }

    // ---- 1-4: one multi-currency account, cash then another wallet -------

    group('one multi-currency account across YER and SAR', () {
      test(
        'a YER entry from نقدًا then a SAR entry from another wallet move only '
        'what they should, and the financial position stays balanced',
        () async {
          final category = await book.categories.create(
            const BookCategoryDraft(name: 'الأصدقاء'),
          );
          final rajhi = await book.wallets.create(
            WalletDraft(
              name: 'محفظة الراجحي',
              openings: const [
                WalletOpeningDraft(currencyCode: 'YER'),
                WalletOpeningDraft(currencyCode: 'SAR'),
              ],
            ),
          );
          final ahmad = await book.accounts.create(
            BookAccountDraft(categoryId: category.id, name: 'أحمد'),
          );

          // Step 2: نقدًا (main wallet), YER, DEBIT 5,000.
          final yerRow = await book.transactions.create(
            BookTransactionDraft(
              accountId: ahmad.id,
              currencyCode: 'YER',
              type: EntryType.debit,
              amountMinor: 5000,
              date: '2026-01-01',
              walletId: seededMainWalletId,
            ),
          );

          expect(await accountBalance(ahmad.id, 'YER'), 5000);
          expect(await walletBalance(seededMainWalletId, 'YER'), -5000);
          // Other currencies of the same account/wallet are untouched.
          expect(await accountBalance(ahmad.id, 'SAR'), isNull);
          expect(await walletBalance(seededMainWalletId, 'SAR'), 0);
          expect(await walletBalance(rajhi.id, 'YER'), 0);
          expect(yerRow.balanceAfter, 5000);
          await expectExactLink(
            yerRow.id,
            walletId: seededMainWalletId,
            currencyCode: 'YER',
            amountMinor: 5000,
            direction: WalletDirection.outgoing,
          );
          await expectAccountConsistent(ahmad.id);
          await expectWalletConsistent(seededMainWalletId);

          var position = await harness.repository.netPosition();
          expect(position.firstWhere((p) => p.currencyCode == 'YER').debitMinor, 5000);

          // Step 3: محفظة الراجحي, SAR, CREDIT 300 (increase — money came in).
          final sarRow = await book.transactions.create(
            BookTransactionDraft(
              accountId: ahmad.id,
              currencyCode: 'SAR',
              type: EntryType.credit,
              amountMinor: 300,
              date: '2026-01-02',
              walletId: rajhi.id,
            ),
          );

          // Its own (account, currency) and (wallet, currency) move…
          expect(await accountBalance(ahmad.id, 'SAR'), -300);
          expect(await walletBalance(rajhi.id, 'SAR'), 300);
          expect(sarRow.balanceAfter, -300);
          // …and nothing else does: the first entry's YER figures, the other
          // wallet, and رجحي's own YER balance are all exactly as before.
          expect(await accountBalance(ahmad.id, 'YER'), 5000);
          expect(await walletBalance(seededMainWalletId, 'YER'), -5000);
          expect(await walletBalance(seededMainWalletId, 'SAR'), 0);
          expect(await walletBalance(rajhi.id, 'YER'), 0);
          await expectExactLink(
            sarRow.id,
            walletId: rajhi.id,
            currencyCode: 'SAR',
            amountMinor: 300,
            direction: WalletDirection.incoming,
          );
          await expectAccountConsistent(ahmad.id);
          await expectWalletConsistent(seededMainWalletId);
          await expectWalletConsistent(rajhi.id);

          // Requirement 9: transferring value between the account side and the
          // wallet side the normal way (opposite signs) neither doubles nor
          // erases it — cash + receivable − payable nets to zero movement in
          // each currency that had no independent opening.
          position = await harness.repository.netPosition();
          final cash = await harness.repository.walletTotalsByCurrency();
          int cashOf(String code) => cash
              .firstWhere(
                (c) => c.currencyCode == code,
                orElse: () => const WalletCurrencyTotal(
                  currencyCode: '',
                  totalMinor: 0,
                  walletCount: 0,
                ),
              )
              .totalMinor;
          final yer = position.firstWhere((p) => p.currencyCode == 'YER');
          final sar = position.firstWhere((p) => p.currencyCode == 'SAR');
          expect(cashOf('YER') + yer.debitMinor - yer.creditMinor, 0);
          expect(cashOf('SAR') + sar.debitMinor - sar.creditMinor, 0);
        },
      );
    });

    // ---- 5: editing a linked transaction every possible way --------------

    group('editing a linked transaction', () {
      late BookAccount ahmad;
      late Wallet rajhi;

      setUp(() async {
        final category = await book.categories.create(
          const BookCategoryDraft(name: 'الأصدقاء'),
        );
        rajhi = await book.wallets.create(
          WalletDraft(
            name: 'محفظة الراجحي',
            openings: const [WalletOpeningDraft(currencyCode: 'YER')],
          ),
        );
        ahmad = await book.accounts.create(
          BookAccountDraft(categoryId: category.id, name: 'أحمد'),
        );
      });

      test('changing the amount reverses the old effect before applying the '
          'new one — no double-counting', () async {
        final row = await book.transactions.create(
          BookTransactionDraft(
            accountId: ahmad.id,
            currencyCode: 'YER',
            type: EntryType.debit,
            amountMinor: 1000,
            date: '2026-01-01',
            walletId: seededMainWalletId,
          ),
        );
        expect(await walletBalance(seededMainWalletId, 'YER'), -1000);

        final updated = await book.transactions.update(
          row.id,
          BookTransactionDraft(
            accountId: ahmad.id,
            currencyCode: 'YER',
            type: EntryType.debit,
            amountMinor: 4000,
            date: '2026-01-01',
            walletId: seededMainWalletId,
          ),
        );

        expect(updated.balanceAfter, 4000);
        expect(await walletBalance(seededMainWalletId, 'YER'), -4000);
        await expectExactLink(
          row.id,
          walletId: seededMainWalletId,
          currencyCode: 'YER',
          amountMinor: 4000,
          direction: WalletDirection.outgoing,
        );
        await expectAccountConsistent(ahmad.id);
        await expectWalletConsistent(seededMainWalletId);
      });

      test('flipping DEBIT to CREDIT flips the wallet effect the same way',
          () async {
        final row = await book.transactions.create(
          BookTransactionDraft(
            accountId: ahmad.id,
            currencyCode: 'YER',
            type: EntryType.debit,
            amountMinor: 1000,
            date: '2026-01-01',
            walletId: seededMainWalletId,
          ),
        );
        expect(await walletBalance(seededMainWalletId, 'YER'), -1000);

        await book.transactions.update(
          row.id,
          BookTransactionDraft(
            accountId: ahmad.id,
            currencyCode: 'YER',
            type: EntryType.credit,
            amountMinor: 1000,
            date: '2026-01-01',
            walletId: seededMainWalletId,
          ),
        );

        expect(await accountBalance(ahmad.id, 'YER'), -1000);
        expect(await walletBalance(seededMainWalletId, 'YER'), 1000);
        await expectExactLink(
          row.id,
          walletId: seededMainWalletId,
          currencyCode: 'YER',
          amountMinor: 1000,
          direction: WalletDirection.incoming,
        );
        await expectAccountConsistent(ahmad.id);
        await expectWalletConsistent(seededMainWalletId);
      });

      test('changing only the date reorders balance_after without touching '
          'the wallet total', () async {
        await book.transactions.create(
          BookTransactionDraft(
            accountId: ahmad.id,
            currencyCode: 'YER',
            type: EntryType.debit,
            amountMinor: 100,
            date: '2026-01-01',
            walletId: seededMainWalletId,
          ),
        );
        final moving = await book.transactions.create(
          BookTransactionDraft(
            accountId: ahmad.id,
            currencyCode: 'YER',
            type: EntryType.debit,
            amountMinor: 200,
            date: '2026-01-05',
            walletId: seededMainWalletId,
          ),
        );
        await book.transactions.create(
          BookTransactionDraft(
            accountId: ahmad.id,
            currencyCode: 'YER',
            type: EntryType.debit,
            amountMinor: 300,
            date: '2026-01-10',
            walletId: seededMainWalletId,
          ),
        );
        expect(await balancesAfter(ahmad.id, 'YER'), [100, 300, 600]);

        // Move the middle row to the very start: running balances reorder,
        // the wallet's total (money out either way) does not change.
        await book.transactions.update(
          moving.id,
          BookTransactionDraft(
            accountId: ahmad.id,
            currencyCode: 'YER',
            type: EntryType.debit,
            amountMinor: 200,
            date: '2025-12-25',
            walletId: seededMainWalletId,
          ),
        );

        expect(await balancesAfter(ahmad.id, 'YER'), [200, 300, 600]);
        expect(await walletBalance(seededMainWalletId, 'YER'), -600);
        await expectAccountConsistent(ahmad.id);
        await expectWalletConsistent(seededMainWalletId);
      });

      test('moving the payment from نقدًا to a wallet, then to another '
          'wallet, leaves exactly one link and clean balances throughout',
          () async {
        final row = await book.transactions.create(
          BookTransactionDraft(
            accountId: ahmad.id,
            currencyCode: 'YER',
            type: EntryType.debit,
            amountMinor: 500,
            date: '2026-01-01',
            walletId: seededMainWalletId,
          ),
        );
        expect(await walletBalance(seededMainWalletId, 'YER'), -500);

        // نقدًا → محفظة الراجحي.
        await book.transactions.update(
          row.id,
          BookTransactionDraft(
            accountId: ahmad.id,
            currencyCode: 'YER',
            type: EntryType.debit,
            amountMinor: 500,
            date: '2026-01-01',
            walletId: rajhi.id,
          ),
        );
        expect(await walletBalance(seededMainWalletId, 'YER'), 0);
        expect(await walletBalance(rajhi.id, 'YER'), -500);
        await expectExactLink(
          row.id,
          walletId: rajhi.id,
          currencyCode: 'YER',
          amountMinor: 500,
          direction: WalletDirection.outgoing,
        );
        await expectWalletConsistent(seededMainWalletId);
        await expectWalletConsistent(rajhi.id);

        // محفظة الراجحي → محفظة أخرى.
        final other = await book.wallets.create(
          WalletDraft.single(name: 'محفظة أخرى', currencyCode: 'YER'),
        );
        await book.transactions.update(
          row.id,
          BookTransactionDraft(
            accountId: ahmad.id,
            currencyCode: 'YER',
            type: EntryType.debit,
            amountMinor: 500,
            date: '2026-01-01',
            walletId: other.id,
          ),
        );
        expect(await walletBalance(rajhi.id, 'YER'), 0);
        expect(await walletBalance(other.id, 'YER'), -500);
        await expectExactLink(
          row.id,
          walletId: other.id,
          currencyCode: 'YER',
          amountMinor: 500,
          direction: WalletDirection.outgoing,
        );
        await expectAccountConsistent(ahmad.id);
        await expectWalletConsistent(rajhi.id);
        await expectWalletConsistent(other.id);
      });

      test('changing the currency to one the wallet already holds moves the '
          'link between (wallet, currency) pairs cleanly', () async {
        await book.wallets.update(
          rajhi.id,
          WalletDraft(
            name: 'محفظة الراجحي',
            openings: const [
              WalletOpeningDraft(currencyCode: 'YER'),
              WalletOpeningDraft(currencyCode: 'SAR'),
            ],
          ),
        );
        final row = await book.transactions.create(
          BookTransactionDraft(
            accountId: ahmad.id,
            currencyCode: 'YER',
            type: EntryType.debit,
            amountMinor: 500,
            date: '2026-01-01',
            walletId: rajhi.id,
          ),
        );
        expect(await walletBalance(rajhi.id, 'YER'), -500);

        await book.transactions.update(
          row.id,
          BookTransactionDraft(
            accountId: ahmad.id,
            currencyCode: 'SAR',
            type: EntryType.debit,
            amountMinor: 50,
            date: '2026-01-01',
            walletId: rajhi.id,
          ),
        );

        expect(await walletBalance(rajhi.id, 'YER'), 0);
        expect(await walletBalance(rajhi.id, 'SAR'), -50);
        expect(await accountBalance(ahmad.id, 'YER'), isNull);
        expect(await accountBalance(ahmad.id, 'SAR'), 50);
        await expectExactLink(
          row.id,
          walletId: rajhi.id,
          currencyCode: 'SAR',
          amountMinor: 50,
          direction: WalletDirection.outgoing,
        );
        await expectWalletConsistent(rajhi.id);
      });

      test('changing the currency to one the wallet does NOT hold is refused, '
          'and nothing moved', () async {
        final row = await book.transactions.create(
          BookTransactionDraft(
            accountId: ahmad.id,
            currencyCode: 'YER',
            type: EntryType.debit,
            amountMinor: 500,
            date: '2026-01-01',
            walletId: rajhi.id,
          ),
        );

        await expectLater(
          book.transactions.update(
            row.id,
            BookTransactionDraft(
              accountId: ahmad.id,
              currencyCode: 'SAR',
              type: EntryType.debit,
              amountMinor: 50,
              date: '2026-01-01',
              walletId: rajhi.id,
            ),
          ),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.code,
              'code',
              'wallet_currency_unsupported',
            ),
          ),
        );

        // Fully unchanged: still YER, still linked at its original amount.
        final unchanged = (await book.transactions.find(row.id))!;
        expect(unchanged.currencyCode, 'YER');
        expect(unchanged.amountMinor, 500);
        expect(await walletBalance(rajhi.id, 'YER'), -500);
        expect(await walletBalance(rajhi.id, 'SAR'), 0);
        await expectExactLink(
          row.id,
          walletId: rajhi.id,
          currencyCode: 'YER',
          amountMinor: 500,
          direction: WalletDirection.outgoing,
        );
        await expectAccountConsistent(ahmad.id);
        await expectWalletConsistent(rajhi.id);
      });
    });

    // ---- 6: soft delete then undo -----------------------------------------

    group('soft delete and undo', () {
      test('deleting then restoring returns the account, the wallet and the '
          'position to exactly their previous values', () async {
        final category = await book.categories.create(
          const BookCategoryDraft(name: 'الأصدقاء'),
        );
        final ahmad = await book.accounts.create(
          BookAccountDraft(categoryId: category.id, name: 'أحمد'),
        );
        await book.transactions.create(
          BookTransactionDraft(
            accountId: ahmad.id,
            currencyCode: 'YER',
            type: EntryType.debit,
            amountMinor: 400,
            date: '2026-01-01',
            walletId: seededMainWalletId,
          ),
        );
        final target = await book.transactions.create(
          BookTransactionDraft(
            accountId: ahmad.id,
            currencyCode: 'YER',
            type: EntryType.debit,
            amountMinor: 900,
            date: '2026-01-05',
            walletId: seededMainWalletId,
          ),
        );

        final beforeAccount = await accountBalance(ahmad.id, 'YER');
        final beforeWallet = await walletBalance(seededMainWalletId, 'YER');
        final beforePosition = (await harness.repository.netPosition())
            .firstWhere((p) => p.currencyCode == 'YER');

        await book.transactions.delete(target.id);
        expect((await book.transactions.find(target.id))!.isDeleted, isTrue);
        expect(await accountBalance(ahmad.id, 'YER'), 400);
        expect(await walletBalance(seededMainWalletId, 'YER'), -400);
        expect((await linkOf(target.id))!.isDeleted, isTrue);

        await book.transactions.restore(target.id);

        expect((await book.transactions.find(target.id))!.isDeleted, isFalse);
        expect(await accountBalance(ahmad.id, 'YER'), beforeAccount);
        expect(await walletBalance(seededMainWalletId, 'YER'), beforeWallet);
        final afterPosition = (await harness.repository.netPosition())
            .firstWhere((p) => p.currencyCode == 'YER');
        expect(afterPosition.debitMinor, beforePosition.debitMinor);
        expect(afterPosition.creditMinor, beforePosition.creditMinor);
        await expectExactLink(
          target.id,
          walletId: seededMainWalletId,
          currencyCode: 'YER',
          amountMinor: 900,
          direction: WalletDirection.outgoing,
        );
        await expectAccountConsistent(ahmad.id);
        await expectWalletConsistent(seededMainWalletId);
      });
    });

    // ---- 7: interleaved multi-currency rows, recompute scoped -------------

    group('interleaved YER and SAR rows', () {
      test('editing an old row rebuilds balance_after for its own currency '
          'only, whatever order the two currencies were entered in', () async {
        final category = await book.categories.create(
          const BookCategoryDraft(name: 'الأصدقاء'),
        );
        final ahmad = await book.accounts.create(
          BookAccountDraft(categoryId: category.id, name: 'أحمد'),
        );
        Future<BookTransaction> tx(String code, int amount, String date) =>
            book.transactions.create(
              BookTransactionDraft(
                accountId: ahmad.id,
                currencyCode: code,
                type: EntryType.debit,
                amountMinor: amount,
                date: date,
                walletId: seededMainWalletId,
              ),
            );

        await tx('YER', 100, '2026-01-01');
        await tx('SAR', 10, '2026-01-02');
        final oldYer = await tx('YER', 200, '2026-01-03');
        await tx('SAR', 20, '2026-01-04');
        await tx('YER', 300, '2026-01-05');

        expect(await balancesAfter(ahmad.id, 'YER'), [100, 300, 600]);
        expect(await balancesAfter(ahmad.id, 'SAR'), [10, 30]);

        // Editing the old YER row must rebuild YER's later rows only — SAR's
        // stored balances must not be rewritten at all.
        await book.transactions.update(
          oldYer.id,
          BookTransactionDraft(
            accountId: ahmad.id,
            currencyCode: 'YER',
            type: EntryType.debit,
            amountMinor: 500,
            date: '2026-01-03',
            walletId: seededMainWalletId,
          ),
        );

        expect(await balancesAfter(ahmad.id, 'YER'), [100, 600, 900]);
        expect(await balancesAfter(ahmad.id, 'SAR'), [10, 30]);
        await expectAccountConsistent(ahmad.id);
        await expectWalletConsistent(seededMainWalletId);
      });
    });

    // ---- 12: a balance_after integrity check for wallets, like accounts --

    group('wallet balance_after integrity (requirement 12)', () {
      test('countWalletBalanceMismatches finds a corrupted row and clears '
          'once it is recomputed', () async {
        final category = await book.categories.create(
          const BookCategoryDraft(name: 'الأصدقاء'),
        );
        final ahmad = await book.accounts.create(
          BookAccountDraft(categoryId: category.id, name: 'أحمد'),
        );
        final row = await book.transactions.create(
          BookTransactionDraft(
            accountId: ahmad.id,
            currencyCode: 'YER',
            type: EntryType.debit,
            amountMinor: 500,
            date: '2026-01-01',
            walletId: seededMainWalletId,
          ),
        );
        expect(
          await harness.repository.countWalletBalanceMismatches(seededMainWalletId),
          0,
        );

        // Corrupt the linked wallet movement's stored balance directly, the
        // same way the account-side test does for `countBalanceMismatches`.
        final link = (await linkOf(row.id))!;
        await harness.repository.write(
          (writer) => writer.updateWalletBalances({link.id: -999999}),
        );

        expect(
          await harness.repository.countWalletBalanceMismatches(seededMainWalletId),
          1,
        );
        // An unrelated wallet is unaffected.
        expect(await harness.repository.countWalletBalanceMismatches('missing'), 0);

        // A real edit (the amount actually changes) walks the same
        // detach/recompute path as requirement 5 and clears the mismatch —
        // a no-op edit (same amount/date/time/wallet/currency) is a documented
        // exception that touches nothing on the wallet side (see
        // `syncWalletLink`'s `sameLink` early return), so it would not.
        await book.transactions.update(
          row.id,
          BookTransactionDraft(
            accountId: ahmad.id,
            currencyCode: 'YER',
            type: EntryType.debit,
            amountMinor: 750,
            date: '2026-01-01',
            walletId: seededMainWalletId,
          ),
        );
        expect(await walletBalance(seededMainWalletId, 'YER'), -750);
        expect(
          await harness.repository.countWalletBalanceMismatches(seededMainWalletId),
          0,
        );
      });
    });
  });
}
