import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/core/models/models.dart';
import 'package:jibi/features/book/book.dart';
import '../../support/test_currencies.dart';
import '../../support/book_wallets.dart';

void main() {
  late InMemoryBookRepository repository;
  late BookServices book;
  late BookAccount account;

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  setUp(() async {
    repository = InMemoryBookRepository();
    await seedMainWallet(repository);
    book = BookServices(
      repository: repository,
      currencies: testCurrencyRegistry(),
      defaultCurrencyCode: () => 'SAR',
    );
    final category = await book.categories.create(
      const BookCategoryDraft(name: 'حسابات اليمن'),
    );
    account = await book.accounts.create(
      BookAccountDraft.single(
        categoryId: category.id,
        name: 'علي أخي',
        currencyCode: 'YER',
      ),
    );
    for (var day = 1; day <= 7; day++) {
      await book.transactions.create(
        BookTransactionDraft(
          accountId: account.id,
          currencyCode: 'YER',
          walletId: seededMainWalletId,
          type: day.isEven ? EntryType.credit : EntryType.debit,
          amountMinor: day * 100,
          date: '2025-01-0$day',
        ),
      );
    }
  });

  tearDown(() => repository.dispose());

  test('loads the first page, then appends the following ones', () async {
    final list = TransactionListController(
      transactions: book.transactions,
      accountId: account.id,
      pageSize: 3,
    );
    addTearDown(list.dispose);
    await settle();

    expect(list.value.loading, isFalse);
    expect(list.value.items.map((r) => r.amountMinor), [700, 600, 500]);
    expect(list.value.hasMore, isTrue);
    expect(list.value.matchCount, 7);

    await list.loadMore();
    expect(list.value.items.map((r) => r.amountMinor), [
      700, 600, 500, 400, 300, 200,
    ]);
    await list.loadMore();
    expect(list.value.items, hasLength(7));
    expect(list.value.hasMore, isFalse);
    // Nothing more to load: no error, no change.
    await list.loadMore();
    expect(list.value.items, hasLength(7));
  });

  test('a write keeps the loaded depth and shows the new row', () async {
    final list = TransactionListController(
      transactions: book.transactions,
      accountId: account.id,
      pageSize: 3,
    );
    addTearDown(list.dispose);
    await settle();
    await list.loadMore();
    expect(list.value.items, hasLength(6));

    await book.transactions.create(
      BookTransactionDraft(
        accountId: account.id,
        currencyCode: 'YER',
        walletId: seededMainWalletId,
        type: EntryType.debit,
        amountMinor: 999,
        date: '2025-02-01',
      ),
    );
    await settle();

    // The same depth is re-read (6 rows): the new row is on top, the oldest
    // loaded row moved down into the not-yet-loaded part.
    expect(list.value.items, hasLength(6));
    expect(list.value.items.first.amountMinor, 999);
    expect(list.value.hasMore, isTrue);
    expect(list.value.matchCount, 8);
  });

  test('filter and sort order reload from the top', () async {
    final list = TransactionListController(
      transactions: book.transactions,
      accountId: account.id,
      pageSize: 50,
    );
    addTearDown(list.dispose);
    await settle();

    await list.setFilter(const BookTransactionFilter(type: EntryType.credit));
    expect(list.value.items.map((r) => r.amountMinor), [600, 400, 200]);
    expect(list.value.matchCount, 3);

    await list.setNewestFirst(false);
    expect(list.value.items.map((r) => r.amountMinor), [200, 400, 600]);

    await list.setFilter(BookTransactionFilter.none);
    expect(list.value.items.first.amountMinor, 100);
  });
}
