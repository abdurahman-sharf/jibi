@Tags(['perf'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/core/database/app_database.dart';
import 'package:jibi/core/database/sqlite_book_repository.dart';
import 'package:jibi/core/models/models.dart';
import 'package:jibi/features/book/book.dart';
import 'package:jibi/features/book/reports/report_builder.dart';
import 'package:jibi/features/book/reports/report_xlsx.dart';
import '../support/test_currencies.dart';
import '../support/book_wallets.dart';

/// How the book behaves with a lot of data (المتطلب 73): one account with tens
/// of thousands of transactions, a long audit log. The limits are generous
/// (several times what a desktop needs) so the test catches a query that
/// stopped using its index, not a slow machine.
const int _rows = 20000;

void main() {
  late Directory sandbox;
  late AppDatabase appDatabase;
  late SqliteBookRepository repository;
  late BookServices book;
  late BookAccount big;
  late BookCategory category;
  final timings = <String, int>{};

  Future<T> timed<T>(String name, Future<T> Function() action) async {
    final watch = Stopwatch()..start();
    final result = await action();
    timings[name] = watch.elapsedMilliseconds;
    return result;
  }

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    sandbox = await Directory.systemTemp.createTemp('jibi_scale_');
    appDatabase = AppDatabase(
      path: '${sandbox.path}${Platform.pathSeparator}scale.sqlite',
    );
    repository = SqliteBookRepository(appDatabase);
    book = BookServices(
      repository: repository,
      currencies: testCurrencyRegistry(),
      defaultCurrencyCode: () => 'SAR',
    );
    category = await book.categories.create(
      const BookCategoryDraft(name: 'حسابات كبيرة'),
    );
    big = await book.accounts.create(
      BookAccountDraft.single(
        categoryId: category.id,
        name: 'حساب كبير',
        currencyCode: 'YER',
      ),
    );
    for (var index = 0; index < 5; index++) {
      await book.accounts.create(
        BookAccountDraft.single(
          categoryId: category.id,
          name: 'حساب $index',
          currencyCode: index.isEven ? 'YER' : 'SAR',
        ),
      );
    }
    // Bulk-load the big account straight into the tables (what the app would
    // have written one by one over the years), with correct running balances.
    final database = await appDatabase.database;
    final batch = database.batch();
    var balance = 0;
    final base = DateTime(2000, 1, 1);
    for (var index = 0; index < _rows; index++) {
      final debit = index % 3 != 0;
      final amount = 100 + (index % 977);
      balance += debit ? amount : -amount;
      final day = base.add(Duration(days: index ~/ 3));
      final date = BookTransaction.formatDate(day);
      final number = 'TX-${(index + 1).toString().padLeft(6, '0')}';
      batch.insert('book_transactions', <String, Object?>{
        'id': 'bulk-$index',
        'transaction_number': number,
        'account_id': big.id,
        'currency_code': 'YER',
        'type': debit ? 'DEBIT' : 'CREDIT',
        'amount_minor': amount,
        'transaction_date': date,
        'transaction_time': '${(index % 24).toString().padLeft(2, '0')}:00',
        'details': index % 50 == 0 ? 'سداد رقم $index' : null,
        'notes': null,
        'balance_after': balance,
        'created_at': 1000000 + index,
        'updated_at': 1000000 + index,
      });
      batch.insert('book_audit_log', <String, Object?>{
        'id': 'audit-$index',
        'entity_type': 'transaction',
        'entity_id': 'bulk-$index',
        'action': 'created',
        'details': '$number ${debit ? 'DEBIT' : 'CREDIT'} $amount',
        'created_at': 1000000 + index,
      });
    }
    // The number counter continues after the loaded rows.
    batch.insert('book_counters', <String, Object?>{
      'name': 'tx_number',
      'value': _rows,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await batch.commit(noResult: true);
  });

  tearDownAll(() async {
    // ignore: avoid_print
    print('SCALE TIMINGS (ms, $_rows rows): $timings');
    await repository.dispose();
    await appDatabase.close();
    try {
      await sandbox.delete(recursive: true);
    } on FileSystemException {
      // Windows keeps SQLite handles briefly after close.
    }
  });

  test('the stored balances are consistent before anything is measured', () async {
    expect(await repository.countBalanceMismatches(big.id), 0);
  });

  test('the first page of the statement is quick', () async {
    final page = await timed(
      'first page',
      () => repository.transactionPage(big.id, limit: 50),
    );

    expect(page.items, hasLength(50));
    expect(page.hasMore, isTrue);
    expect(timings['first page'], lessThan(500));
  });

  test('a page deep in the statement is as quick (keyset paging)', () async {
    final first = await repository.transactionPage(big.id, limit: 50);
    var cursor = BookOrderKey.of(first.items.last);
    late TransactionPage page;
    final watch = Stopwatch()..start();
    // Walk 100 pages down (5,000 rows), timing the walk.
    for (var index = 0; index < 100; index++) {
      page = await repository.transactionPage(big.id, after: cursor, limit: 50);
      cursor = BookOrderKey.of(page.items.last);
    }
    timings['100 pages'] = watch.elapsedMilliseconds;

    expect(page.items, hasLength(50));
    expect(timings['100 pages'], lessThan(5000));
  });

  test('totals, summaries and search over every row', () async {
    final summaries = await timed(
      'account summaries',
      () => repository.accountSummaries(),
    );
    final categorySummaries = await timed(
      'category summaries',
      () => repository.categorySummaries(),
    );
    final position = await timed('net position', repository.netPosition);
    final searched = await timed(
      'search text',
      () => repository.filteredTotals(
        big.id,
        filter: const BookTransactionFilter(text: 'سداد'),
      ),
    );

    expect(
      summaries.firstWhere((s) => s.account.id == big.id).transactionCount,
      _rows,
    );
    expect(categorySummaries, isNotEmpty);
    expect(position, isNotEmpty);
    expect(searched.single.transactionCount, _rows ~/ 50);
    for (final name in [
      'account summaries',
      'category summaries',
      'net position',
      'search text',
    ]) {
      expect(timings[name], lessThan(3000), reason: name);
    }
  });

  test('the audit log pages quickly even with a long history', () async {
    final first = await timed(
      'audit first page',
      () => repository.auditPage(limit: 40),
    );
    final deep = await timed(
      'audit deep page',
      () => repository.auditPage(after: first.items.last, limit: 40),
    );
    final scoped = await timed(
      'audit for account',
      () => repository.auditPage(accountId: big.id, limit: 40),
    );

    expect(first.items, hasLength(40));
    expect(deep.items, hasLength(40));
    expect(scoped.items, hasLength(40));
    expect(first.hasMore, isTrue);
    for (final name in ['audit first page', 'audit deep page', 'audit for account']) {
      expect(timings[name], lessThan(3000), reason: name);
    }
  });

  test('an old transaction rebalances every later one in one go', () async {
    final created = await timed(
      'insert at the start',
      () => book.transactions.create(
        BookTransactionDraft(
          accountId: big.id,
          currencyCode: 'YER',
          walletId: seededMainWalletId,
          type: EntryType.debit,
          amountMinor: 12345,
          date: '1999-12-31',
        ),
      ),
    );
    expect(created.balanceAfter, 12345);
    expect(await repository.countBalanceMismatches(big.id), 0);

    final updated = await timed(
      'edit the oldest amount',
      () => book.transactions.update(
        created.id,
        BookTransactionDraft(
          accountId: big.id,
          currencyCode: 'YER',
          walletId: seededMainWalletId,
          type: EntryType.debit,
          amountMinor: 999,
          date: '1999-12-31',
        ),
      ),
    );
    expect(updated.balanceAfter, 999);

    await timed('delete the oldest', () => book.transactions.delete(created.id));
    expect(await repository.countBalanceMismatches(big.id), 0);
    // Rewriting 20,000 balances is the worst case an edit can cause.
    for (final name in [
      'insert at the start',
      'edit the oldest amount',
      'delete the oldest',
    ]) {
      expect(timings[name], lessThan(15000), reason: name);
    }
  });

  test('a statement of 5,000 rows builds and exports without trouble', () async {
    final reports = BookReportBuilder(
      repository: repository,
      currencies: testCurrencyRegistry(),
    );
    final document = await timed(
      'build statement (year 2000-2013)',
      () => reports.accountStatement(
        big.id,
        fromDate: '2000-01-01',
        toDate: '2013-12-31',
      ),
    );
    final rows = document.rowCount;
    final bytes = await timed(
      'xlsx of the statement',
      () async => ReportXlsxWriter().write(document),
    );

    expect(rows, greaterThan(4000));
    expect(bytes.length, greaterThan(10000));
    expect(timings['build statement (year 2000-2013)'], lessThan(10000));
    expect(timings['xlsx of the statement'], lessThan(20000));
  });
}
