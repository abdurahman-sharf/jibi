
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/core/database/app_database.dart';
import 'package:jibi/core/database/sqlite_book_repository.dart';
import 'package:jibi/core/models/models.dart';
import 'package:jibi/core/repositories/book_repository.dart';
import 'package:jibi/features/book/book.dart';
import '../../support/test_currencies.dart';
import '../../support/book_wallets.dart';

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

  group('BookAuditText', _textSuite);
}

void _suite(String name, Future<_Harness> Function() open) {
  group('audit log of the $name', () {
    late _Harness harness;
    late CurrencyRegistry currencies;
    late CategoriesController categories;
    late BookAccountsController accounts;
    late TransactionsController transactions;
    var sequence = 0;

    setUp(() async {
      sequence = 0;
      harness = await open();
      await seedMainWallet(harness.repository);
      currencies = testCurrencyRegistry();
      String newId() => 'id-${++sequence}';
      categories = CategoriesController(
        repository: harness.repository,
        newId: newId,
      );
      accounts = BookAccountsController(
        repository: harness.repository,
        currencies: currencies,
        newId: newId,
      );
      transactions = TransactionsController(
        repository: harness.repository,
        currencies: currencies,
        newId: newId,
      );
    });

    tearDown(() => harness.dispose());

    Future<BookAccount> account(
      BookCategory category,
      String name,
      String currency,
    ) => accounts.create(
      BookAccountDraft.single(
        categoryId: category.id,
        name: name,
        currencyCode: currency,
      ),
    );

    Future<BookTransaction> tx(
      BookAccount account,
      EntryType type,
      int amount, {
      String date = '2026-01-10',
      String currency = 'YER',
    }) => transactions.create(
      BookTransactionDraft(
        accountId: account.id,
        currencyCode: currency,
        walletId: seededMainWalletId,
        type: type,
        amountMinor: amount,
        date: date,
      ),
    );

    Future<List<BookAuditEntry>> all({
      String? accountId,
      BookAuditEntity? entity,
    }) async => (await harness.repository.auditPage(
      accountId: accountId,
      entity: entity,
      limit: 500,
    )).items;

    test('records a transaction\'s life, newest first, with names resolved', () async {
      final category = await categories.create(
        const BookCategoryDraft(name: 'حسابات اليمن'),
      );
      final ali = await account(category, 'علي أخي', 'YER');
      final created = await tx(ali, EntryType.debit, 30000);
      await transactions.update(
        created.id,
        BookTransactionDraft(
          accountId: ali.id,
          currencyCode: 'YER',
          walletId: seededMainWalletId,
          type: EntryType.credit,
          amountMinor: 20000,
          date: '2026-02-01',
          details: 'جديد',
        ),
      );
      await transactions.delete(created.id);
      await transactions.restore(created.id);

      final entries = await all(entity: BookAuditEntity.transaction);
      final actions = entries.map((entry) => entry.action).toList();

      // Newest first: restored, deleted, then the four edits of the update
      // (written in this order), then created.
      expect(actions.first, 'restored');
      expect(actions[1], 'deleted');
      expect(actions.last, 'created');
      expect(
        actions.sublist(2, actions.length - 1),
        unorderedEquals([
          'amount_changed',
          'date_changed',
          'type_changed',
          'updated',
        ]),
      );
      // The order of writing inside one update is kept.
      expect(
        actions.sublist(2, actions.length - 1),
        ['updated', 'type_changed', 'date_changed', 'amount_changed'],
      );
      for (final entry in entries) {
        expect(entry.transactionNumber, created.number);
        expect(entry.accountName, 'علي أخي');
        expect(entry.currencyCode, 'YER');
        expect(entry.accountId, ali.id);
      }
      // The writer records the transaction's own currency with the amount.
      expect(entries.last.details, '${created.number} DEBIT 30000 YER');
      final amount = entries.firstWhere((entry) => entry.action == 'amount_changed');
      expect(amount.details, '30000->20000');
    });

    test('a deleted transaction still names its account', () async {
      final category = await categories.create(
        const BookCategoryDraft(name: 'ت'),
      );
      final sar = await account(category, 'حساب سعودي', 'SAR');
      final row = await tx(sar, EntryType.debit, 48500, currency: 'SAR');
      await transactions.delete(row.id);

      final deleted = (await all()).firstWhere((entry) => entry.action == 'deleted');

      expect(deleted.accountName, 'حساب سعودي');
      expect(deleted.currencyCode, 'SAR');
      expect(deleted.transactionNumber, row.number);
    });

    test('entries written at the same moment keep their writing order', () async {
      final category = await categories.create(
        const BookCategoryDraft(name: 'ت'),
      );
      final ali = await account(category, 'علي', 'YER');
      final numbers = <String>[];
      for (var index = 0; index < 8; index++) {
        numbers.add((await tx(ali, EntryType.debit, 100 + index)).number);
      }

      final created = (await all(entity: BookAuditEntity.transaction))
          .map((entry) => entry.transactionNumber)
          .toList();

      expect(created, numbers.reversed.toList());
    });

    test('an account filter keeps that account and its transactions', () async {
      final category = await categories.create(
        const BookCategoryDraft(name: 'ت'),
      );
      final ali = await account(category, 'علي', 'YER');
      final omar = await account(category, 'عمر', 'YER');
      await tx(ali, EntryType.debit, 100);
      await tx(omar, EntryType.debit, 200);
      await tx(ali, EntryType.credit, 50);

      final entries = await all(accountId: ali.id);

      expect(entries.every((entry) => entry.accountId == ali.id), isTrue);
      // The account itself plus its two transactions.
      expect(entries, hasLength(3));
      expect(
        entries.map((entry) => entry.entity),
        containsAll([BookAuditEntity.account, BookAuditEntity.transaction]),
      );
    });

    test('an entity filter keeps one kind', () async {
      final category = await categories.create(
        const BookCategoryDraft(name: 'ت'),
      );
      final ali = await account(category, 'علي', 'YER');
      await tx(ali, EntryType.debit, 100);

      expect(
        (await all(entity: BookAuditEntity.category)).map((e) => e.action),
        ['created'],
      );
      expect(
        (await all(entity: BookAuditEntity.account)).map((e) => e.action),
        ['created'],
      );
      expect(await all(entity: BookAuditEntity.transaction), hasLength(1));
      expect(await all(), hasLength(3));
    });

    test('account and category changes are recorded with their names', () async {
      final category = await categories.create(
        const BookCategoryDraft(name: 'حسابات اليمن'),
      );
      final ali = await account(category, 'علي أخي', 'YER');
      await accounts.setStatus(ali.id, BookAccountStatus.archived);
      await categories.setArchived(category.id, archived: true);

      final accountEvents = await all(entity: BookAuditEntity.account);
      expect(accountEvents.map((e) => e.action), ['status', 'created']);
      expect(accountEvents.first.details, 'archived');
      expect(accountEvents.first.accountName, 'علي أخي');
      final categoryEvents = await all(entity: BookAuditEntity.category);
      expect(categoryEvents.map((e) => e.action), ['archived', 'created']);
      expect(categoryEvents.first.categoryName, 'حسابات اليمن');
    });

    test('pages of the log join without gaps or repeats', () async {
      final category = await categories.create(
        const BookCategoryDraft(name: 'ت'),
      );
      final ali = await account(category, 'علي', 'YER');
      for (var index = 0; index < 9; index++) {
        await tx(ali, EntryType.debit, 100 + index);
      }
      final everything = await all();

      final seen = <String>[];
      BookAuditEntry? cursor;
      var pages = 0;
      while (true) {
        final page = await harness.repository.auditPage(after: cursor, limit: 4);
        seen.addAll(page.items.map((entry) => entry.id));
        pages++;
        if (!page.hasMore) break;
        cursor = page.items.last;
      }

      expect(seen, everything.map((entry) => entry.id).toList());
      expect(seen.toSet(), hasLength(seen.length));
      // 9 transactions + the category + the account = 11 entries.
      expect(everything, hasLength(11));
      expect(pages, 3);
    });

    test('an empty log gives an empty page', () async {
      final page = await harness.repository.auditPage();

      expect(page.items, isEmpty);
      expect(page.hasMore, isFalse);
    });
  });
}

void _textSuite() {
  final currencies = testCurrencyRegistry();
  BookAuditText text([BookPreferences preferences = BookPreferences.standard]) =>
      BookAuditText(preferences: preferences, currencies: currencies);

  BookAuditEntry entry(
    String action, {
    BookAuditEntity entity = BookAuditEntity.transaction,
    String? details,
    String? number = 'TX-000001',
    String? accountName = 'علي أخي',
    String? currency = 'YER',
    String? categoryName,
  }) => BookAuditEntry(
    id: 'x',
    sequence: 1,
    entity: entity,
    entityId: 'e',
    action: action,
    details: details,
    createdAt: DateTime.utc(2026, 9, 20),
    accountName: accountName,
    currencyCode: currency,
    transactionNumber: number,
    categoryName: categoryName,
  );

  test('created shows the side and the amount in the account\'s currency', () {
    final line = text().describe(
      entry('created', details: 'TX-000001 DEBIT 30000'),
    );

    expect(line.kind, BookAuditKind.created);
    expect(line.title, 'تم إنشاء العملية TX-000001');
    expect(line.detail, 'مدين 30,000 YER');
  });

  test('a created entry names its own currency', () {
    // The details carry the currency; the live row is only a fallback.
    final line = text().describe(
      entry('created', details: 'TX-000003 DEBIT 10000 SAR', currency: 'YER'),
    );
    expect(line.detail, 'مدين 100.00 SAR');
  });

  test('a currency change shows both amounts in their own currencies', () {
    final line = text().describe(
      entry('currency_changed', details: '500 YER->30000 SAR', currency: 'SAR'),
    );
    expect(line.kind, BookAuditKind.edited);
    expect(line.title, 'تم تغيير عملة العملية TX-000001');
    expect(line.detail, 'من 500 YER إلى 300.00 SAR');
  });

  test('an opening balance change reads per currency', () {
    final line = text().describe(
      entry(
        'opening_changed',
        entity: BookAuditEntity.account,
        details: 'SAR DEBIT:1000->CREDIT:30000',
        number: null,
      ),
    );
    expect(line.title, 'تم تعديل الرصيد الافتتاحي في الحساب علي أخي');
    expect(line.detail, 'من مدين 10.00 SAR إلى دائن 300.00 SAR');

    final added = text().describe(
      entry(
        'opening_changed',
        entity: BookAuditEntity.account,
        details: 'USD ZERO:0->DEBIT:2000',
        number: null,
      ),
    );
    expect(added.detail, 'من صفر إلى مدين 20.00 USD');
  });

  test('amounts follow the decimals of the currency', () {
    final line = text().describe(
      entry('created', details: 'TX-000002 CREDIT 485000', currency: 'SAR'),
    );

    expect(line.detail, 'دائن 4,850.00 SAR');
  });

  test('an amount change says from and to', () {
    final line = text().describe(
      entry('amount_changed', details: '30000->20000'),
    );

    expect(line.kind, BookAuditKind.edited);
    expect(line.title, 'تم تعديل مبلغ العملية TX-000001');
    expect(line.detail, 'من 30,000 YER إلى 20,000 YER');
  });

  test('a date change follows the chosen date format', () {
    final line = text(
      const BookPreferences(dateFormat: DateDisplayFormat.dayMonthYearSlash),
    ).describe(
      entry('date_changed', details: '2024-12-13 09:30->2025-01-02 00:00'),
    );

    expect(line.title, 'تم تعديل تاريخ العملية TX-000001');
    expect(line.detail, 'من 13/12/2024 09:30 إلى 02/01/2025 00:00');
  });

  test('a type change uses the custom wording of the sides', () {
    const wording = BookPreferences(
      labels: BookLabels(
        debit: 'مستحق لي',
        credit: 'مستحق علي',
        debitHint: '',
        creditHint: '',
      ),
    );

    final standard = text().describe(
      entry('type_changed', details: 'DEBIT->CREDIT'),
    );
    final custom = text(wording).describe(
      entry('type_changed', details: 'DEBIT->CREDIT'),
    );

    expect(standard.title, 'تم تغيير العملية TX-000001 من مدين إلى دائن');
    expect(custom.title, 'تم تغيير العملية TX-000001 من مستحق لي إلى مستحق علي');
  });

  test('delete, restore and attachments', () {
    expect(
      text().describe(entry('deleted', details: 'TX-000001 30000')).detail,
      '30,000 YER',
    );
    expect(text().describe(entry('deleted')).kind, BookAuditKind.deleted);
    expect(
      text().describe(entry('restored')).title,
      'تم استرجاع العملية TX-000001',
    );
    final added = text().describe(
      entry('attachment_added', details: 'سند.jpg'),
    );
    expect(added.kind, BookAuditKind.attachment);
    expect(added.title, 'أُضيف مرفق إلى العملية TX-000001');
    expect(added.detail, 'سند.jpg');
    expect(
      text().describe(entry('attachment_removed', details: 'سند.jpg')).title,
      'حُذف مرفق من العملية TX-000001',
    );
  });

  test('accounts and categories are named', () {
    final account = BookAuditEntity.account;
    expect(
      text().describe(entry('created', entity: account, number: null)).title,
      'تم إنشاء الحساب علي أخي',
    );
    expect(
      text()
          .describe(entry('status', entity: account, details: 'suspended', number: null))
          .title,
      'تم إيقاف الحساب علي أخي',
    );
    expect(
      text()
          .describe(entry('status', entity: account, details: 'archived', number: null))
          .kind,
      BookAuditKind.status,
    );
    final category = BookAuditEntity.category;
    expect(
      text()
          .describe(
            entry('archived', entity: category, number: null, categoryName: 'حسابات اليمن'),
          )
          .title,
      'تمت أرشفة التصنيف حسابات اليمن',
    );
    expect(
      text()
          .describe(entry('activated', entity: category, number: null, categoryName: 'ب'))
          .title,
      'تم تفعيل التصنيف ب',
    );
  });

  test('a removed account is still named from what was recorded', () {
    final line = text().describe(
      entry(
        'deleted',
        entity: BookAuditEntity.account,
        details: 'حساب قديم',
        accountName: null,
        number: null,
      ),
    );

    expect(line.title, 'تم حذف الحساب حساب قديم');
  });

  test('unknown or damaged details never break the line', () {
    expect(text().describe(entry('amount_changed', details: 'garbage')).detail, isNull);
    expect(text().describe(entry('created', details: 'x')).detail, isNull);
    expect(text().describe(entry('date_changed')).title, contains('تاريخ'));
    expect(text().describe(entry('something_new')).title, 'تعديل على العملية TX-000001');
    expect(
      text().describe(entry('something_new', entity: BookAuditEntity.category)).title,
      'تعديل على التصنيف',
    );
  });

  test('a transaction that cannot be found is named from its recorded number', () {
    final line = text().describe(
      entry('created', details: 'TX-000007 DEBIT 100', number: null, accountName: null),
    );

    expect(line.title, 'تم إنشاء العملية TX-000007');
  });
}
