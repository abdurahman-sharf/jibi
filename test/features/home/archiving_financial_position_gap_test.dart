import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/core/database/app_database.dart';
import 'package:jibi/core/database/sqlite_book_repository.dart';
import 'package:jibi/core/models/models.dart';
import 'package:jibi/core/repositories/book_repository.dart';
import 'package:jibi/features/book/book.dart';
import 'package:jibi/features/wallets/wallets.dart';
import '../../support/book_wallets.dart';
import '../../support/test_currencies.dart';

/// Requirement 10 of the financial-cycle review: archiving a wallet or an
/// account is a ONE-SIDED switch — [BookRepository.netPosition] drops an
/// archived account (or one of an inactive/archived category) and
/// [BookRepository.walletTotalsByCurrency] drops an archived wallet,
/// independently of each other (see their doc comments in
/// `book_repository.dart`). A book transaction linked to a wallet stays live
/// on both sides until someone deletes or edits it, so archiving only one end
/// of that link makes the home screen's financial position (cash + receivable
/// − payable) stop netting to zero for a perfectly ordinary linked
/// transaction — money looks like it appeared or vanished, even though
/// nothing was deleted and every stored `balance_after` is still correct.
///
/// These tests DOCUMENT the current, reproducible behaviour; they do not
/// assert it is correct. Fixing it is a product decision (see the report this
/// suite was written for): options include blocking the archive while a live
/// linked transaction exists, keeping an archived entity's linked side in the
/// totals until the link itself is removed, or showing archived cash/position
/// as a separate memo line. If that decision changes this behaviour on
/// purpose, update or remove these tests along with it.
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

    int pick(List<Money> amounts, String code) {
      for (final amount in amounts) {
        if (amount.currencyCode == code) return amount.amountMinor;
      }
      return 0;
    }

    Future<int> netYer() async {
      final position = await harness.repository.netPosition();
      final cash = await harness.repository.walletTotalsByCurrency();
      final receivable = <Money>[
        for (final p in position)
          if (p.debitMinor > 0) Money(amountMinor: p.debitMinor, currencyCode: p.currencyCode),
      ];
      final payable = <Money>[
        for (final p in position)
          if (p.creditMinor > 0) Money(amountMinor: p.creditMinor, currencyCode: p.currencyCode),
      ];
      final cashMoney = <Money>[
        for (final c in cash) Money(amountMinor: c.totalMinor, currencyCode: c.currencyCode),
      ];
      return pick(cashMoney, 'YER') + pick(receivable, 'YER') - pick(payable, 'YER');
    }

    test(
      'archiving the WALLET side of a live linked transaction makes cash '
      'seem to appear from nowhere in the home position',
      () async {
        final category = await book.categories.create(
          const BookCategoryDraft(name: 'الأصدقاء'),
        );
        final rajhi = await book.wallets.create(
          WalletDraft.single(name: 'محفظة الراجحي', currencyCode: 'YER'),
        );
        final ahmad = await book.accounts.create(
          BookAccountDraft(categoryId: category.id, name: 'أحمد'),
        );
        await book.transactions.create(
          BookTransactionDraft(
            accountId: ahmad.id,
            currencyCode: 'YER',
            type: EntryType.debit,
            amountMinor: 500,
            date: '2026-01-01',
            walletId: rajhi.id,
          ),
        );

        // Before archiving: a normal linked transaction nets to zero — the
        // 500 the wallet paid out is exactly offset by the 500 أحمد now owes.
        expect(await netYer(), 0);

        await book.wallets.setStatus(rajhi.id, WalletStatus.archived);

        // The account, the transaction and every stored balance are
        // untouched — أحمد still owes 500, رجحي's ledger still shows -500 —
        // but the wallet's negative cash silently drops out of the home
        // totals (walletTotalsByCurrency skips archived wallets entirely)
        // while the receivable it is supposed to offset stays in. 500 YER of
        // net worth appears to have been created out of nothing.
        expect((await harness.repository.accountSummary(ahmad.id))!.totalsOf('YER')!.netMinor, 500);
        expect((await harness.repository.walletSummary(rajhi.id))!.balanceOf('YER'), -500);
        expect(await netYer(), 500, reason: 'KNOWN GAP: see requirement 10 in the report');
      },
    );

    test(
      'archiving the ACCOUNT side of a live linked transaction makes the '
      'offsetting cash seem to vanish from the home position',
      () async {
        final category = await book.categories.create(
          const BookCategoryDraft(name: 'الأصدقاء'),
        );
        final rajhi = await book.wallets.create(
          WalletDraft.single(name: 'محفظة الراجحي', currencyCode: 'YER'),
        );
        final ahmad = await book.accounts.create(
          BookAccountDraft(categoryId: category.id, name: 'أحمد'),
        );
        await book.transactions.create(
          BookTransactionDraft(
            accountId: ahmad.id,
            currencyCode: 'YER',
            type: EntryType.debit,
            amountMinor: 500,
            date: '2026-01-01',
            walletId: rajhi.id,
          ),
        );
        expect(await netYer(), 0);

        await book.accounts.setStatus(ahmad.id, BookAccountStatus.archived);

        // Now the other way round: the wallet still shows -500 (money really
        // left it), but its offsetting receivable drops out of netPosition
        // because the account is archived. Net worth appears to have
        // shrunk by 500 YER with no real event.
        expect((await harness.repository.walletSummary(rajhi.id))!.balanceOf('YER'), -500);
        expect(await netYer(), -500, reason: 'KNOWN GAP: see requirement 10 in the report');
      },
    );

    test(
      'switching the CATEGORY off has the same effect as archiving its '
      'accounts, for every account under it at once',
      () async {
        final category = await book.categories.create(
          const BookCategoryDraft(name: 'الأصدقاء'),
        );
        final rajhi = await book.wallets.create(
          WalletDraft.single(name: 'محفظة الراجحي', currencyCode: 'YER'),
        );
        final ahmad = await book.accounts.create(
          BookAccountDraft(categoryId: category.id, name: 'أحمد'),
        );
        await book.transactions.create(
          BookTransactionDraft(
            accountId: ahmad.id,
            currencyCode: 'YER',
            type: EntryType.debit,
            amountMinor: 500,
            date: '2026-01-01',
            walletId: rajhi.id,
          ),
        );
        expect(await netYer(), 0);

        await book.categories.setActive(category.id, isActive: false);

        expect(await netYer(), -500, reason: 'KNOWN GAP: see requirement 10 in the report');
      },
    );
  });
}
