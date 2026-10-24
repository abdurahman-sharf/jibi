import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/core/database/app_database.dart';
import 'package:jibi/core/database/sqlite_book_repository.dart';
import 'package:jibi/core/models/models.dart';
import 'package:jibi/core/repositories/book_repository.dart';
import 'package:jibi/features/book/book.dart';
import 'package:jibi/features/home/presentation/dashboard_summary.dart';
import 'package:jibi/features/wallets/wallets.dart';
import '../../support/book_wallets.dart';
import '../../support/test_currencies.dart';

/// The financial position of the home screen, currency by currency, once an
/// account can use several currencies: each transaction counts in ITS OWN
/// currency (not in a currency of its account), the cash of the wallets is
/// per currency, and nothing is converted or added across them.
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

    Future<DashboardSummary> summary() async => DashboardSummary.of(
      position: await harness.repository.netPosition(),
      walletTotals: await harness.repository.walletTotalsByCurrency(),
    );

    int pick(List<Money> amounts, String code) {
      for (final amount in amounts) {
        if (amount.currencyCode == code) return amount.amountMinor;
      }
      return 0;
    }

    /// What the hero card of that currency shows: cash + owed to the user −
    /// owed by the user, in that currency alone.
    int net(DashboardSummary s, String code) =>
        pick(s.cash, code) + pick(s.receivable, code) - pick(s.payable, code);

    test('every currency is its own position: cash and accounts of THAT '
        'currency only', () async {
      final category = await book.categories.create(
        const BookCategoryDraft(name: 'حسابات'),
      );
      final mohammed = await book.accounts.create(
        BookAccountDraft(
          categoryId: category.id,
          name: 'محمد خالد',
          openings: const [
            BookAccountOpeningDraft(
              currencyCode: 'SAR',
              openingMinor: 1000,
              openingType: OpeningType.debit,
            ),
            BookAccountOpeningDraft(
              currencyCode: 'USD',
              openingMinor: 500,
              openingType: OpeningType.credit,
            ),
          ],
        ),
      );
      // The user's own cash: 700 YER and 20.00 USD (deposits, no account).
      await book.walletTransactions.deposit(
        WalletDepositDraft(
          walletId: seededMainWalletId,
          currencyCode: 'YER',
          amountMinor: 700,
          date: '2025-01-01',
        ),
      );
      await book.walletTransactions.deposit(
        WalletDepositDraft(
          walletId: seededMainWalletId,
          currencyCode: 'USD',
          amountMinor: 2000,
          date: '2025-01-01',
        ),
      );
      // محمد: the user gave him 50,000 YER (cash out, he owes), took 300.00 SAR
      // (cash in, the user owes) and gave him 20.00 USD.
      Future<void> tx(String code, EntryType type, int minor) =>
          book.transactions.create(
            BookTransactionDraft(
              accountId: mohammed.id,
              currencyCode: code,
              type: type,
              amountMinor: minor,
              date: '2025-02-01',
              walletId: seededMainWalletId,
            ),
          );
      await tx('YER', EntryType.debit, 50000);
      await tx('SAR', EntryType.credit, 30000);
      await tx('USD', EntryType.debit, 2000);

      final s = await summary();

      // YER: cash 700 − 50,000; he owes 50,000.
      expect(pick(s.cash, 'YER'), -49300);
      expect(pick(s.receivable, 'YER'), 50000);
      expect(pick(s.payable, 'YER'), 0);
      expect(net(s, 'YER'), 700, reason: 'only the deposit is really the user\'s');

      // SAR: opening he owes 10.00, then the user owes him 300.00 net.
      expect(pick(s.receivable, 'SAR'), 1000);
      expect(pick(s.payable, 'SAR'), 30000);
      expect(pick(s.cash, 'SAR'), 30000);
      expect(net(s, 'SAR'), 30000 + 1000 - 30000);

      // USD: the user owes 5.00 (opening), he owes 20.00 more, cash 20 − 20.
      expect(pick(s.payable, 'USD'), 500);
      expect(pick(s.receivable, 'USD'), 2000);
      expect(pick(s.cash, 'USD'), 0);
      expect(net(s, 'USD'), 0 + 2000 - 500);

      // No currency's numbers leak into another, and there is no grand total.
      final codes = {
        for (final m in [...s.cash, ...s.receivable, ...s.payable]) m.currencyCode,
      };
      expect(codes, {'YER', 'SAR', 'USD'});
    });

    test('an account of several currencies feeds several positions, once each',
        () async {
      final category = await book.categories.create(
        const BookCategoryDraft(name: 'حسابات'),
      );
      final one = await book.accounts.create(
        BookAccountDraft(categoryId: category.id, name: 'واحد'),
      );
      final two = await book.accounts.create(
        BookAccountDraft(categoryId: category.id, name: 'اثنان'),
      );
      Future<void> tx(BookAccount a, String code, int minor) =>
          book.transactions.create(
            BookTransactionDraft(
              accountId: a.id,
              currencyCode: code,
              type: EntryType.debit,
              amountMinor: minor,
              date: '2025-02-01',
              walletId: seededMainWalletId,
            ),
          );
      await tx(one, 'YER', 100);
      await tx(one, 'SAR', 200);
      await tx(two, 'YER', 400);

      final position = await harness.repository.netPosition();
      expect(position.map((p) => p.currencyCode), ['SAR', 'YER']);
      expect(position.firstWhere((p) => p.currencyCode == 'YER').debitMinor, 500);
      expect(position.firstWhere((p) => p.currencyCode == 'YER').accountCount, 2);
      expect(position.firstWhere((p) => p.currencyCode == 'SAR').debitMinor, 200);
      expect(position.firstWhere((p) => p.currencyCode == 'SAR').accountCount, 1);
    });

    test('changing a transaction\'s currency moves it between positions',
        () async {
      final category = await book.categories.create(
        const BookCategoryDraft(name: 'حسابات'),
      );
      final a = await book.accounts.create(
        BookAccountDraft(categoryId: category.id, name: 'واحد'),
      );
      final row = await book.transactions.create(
        BookTransactionDraft(
          accountId: a.id,
          currencyCode: 'YER',
          type: EntryType.debit,
          amountMinor: 900,
          date: '2025-02-01',
          walletId: seededMainWalletId,
        ),
      );
      var s = await summary();
      expect(pick(s.receivable, 'YER'), 900);
      expect(pick(s.cash, 'YER'), -900);

      await book.transactions.update(
        row.id,
        BookTransactionDraft(
          accountId: a.id,
          currencyCode: 'SAR',
          type: EntryType.debit,
          amountMinor: 900,
          date: '2025-02-01',
          walletId: seededMainWalletId,
        ),
      );
      s = await summary();
      expect(pick(s.receivable, 'YER'), 0);
      expect(pick(s.cash, 'YER'), 0);
      expect(pick(s.receivable, 'SAR'), 900);
      expect(pick(s.cash, 'SAR'), -900);
    });
  });
}
