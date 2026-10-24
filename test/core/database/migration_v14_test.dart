import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/core/database/app_database.dart';
import 'package:jibi/core/database/sqlite_book_repository.dart';
import 'package:jibi/core/models/models.dart';
import 'package:jibi/core/errors/app_exception.dart';
import 'package:jibi/features/book/book.dart';
import 'package:jibi/features/book/reports/report_builder.dart';
import 'package:jibi/features/wallets/wallets.dart';
import '../../support/test_currencies.dart';

/// Schema v14: an account holds several currencies. `book_transactions` gets its
/// own `currency_code`, the opening balance moves to `book_account_balances`
/// (one row per account and currency) and `book_accounts` loses its currency
/// and opening columns. These tests start from a REAL v13 database file — with
/// openings on both sides, deleted rows, a wallet-linked transaction and an
/// attachment already in it — and check that nothing is lost across the rebuild
/// of the four tables involved.
void main() {
  late Directory sandbox;
  late String path;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('jibi_migration_v14_');
    path = '${sandbox.path}${Platform.pathSeparator}database.sqlite';
  });

  tearDown(() async {
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
  });

  const v13Migrations = <DatabaseMigration>[
    MigrationV1(),
    MigrationV2(),
    MigrationV3(),
    MigrationV4(),
    MigrationV5(),
    MigrationV6(),
    MigrationV7(),
    MigrationV8(),
    MigrationV9(),
    MigrationV10(),
    MigrationV11(),
    MigrationV12(),
    MigrationV13(),
  ];

  /// Builds a v13 database (foreign keys on, like the app) at [path], then lets
  /// [seed] add rows.
  Future<void> createV13(Future<void> Function(Transaction txn) seed) async {
    final legacy = await openDatabase(
      path,
      version: 13,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, version) => db.transaction((txn) async {
        for (final migration in v13Migrations) {
          await migration.apply(txn);
        }
        await seed(txn);
      }),
    );
    await legacy.close();
  }

  /// One category with four accounts (one currency each, as v13 had):
  ///
  /// - `a-yer`: YER, opening DEBIT 5,000 — a debit of 1,000, a credit of 200
  ///   and a soft-deleted debit of 999; the last live balance is 5,800.
  /// - `a-sar`: SAR, opening CREDIT 300 — a debit of 100 paid through the main
  ///   wallet (with its linked wallet movement) and an attachment on it.
  /// - `a-usd`: USD, no opening — no transactions at all.
  /// - `a-odd`: YER, an inconsistent row (type DEBIT but amount 0) that must be
  ///   normalised to a zero opening instead of failing the upgrade.
  Future<void> seedBook(Transaction txn) async {
    await txn.insert('book_categories', <String, Object?>{
      'id': 'cat',
      'name': 'الأصدقاء',
      'created_at': 1,
      'updated_at': 1,
    });
    Future<void> account(
      String id,
      String currency, {
      int opening = 0,
      String type = 'ZERO',
      String? phone,
    }) => txn.insert('book_accounts', <String, Object?>{
      'id': id,
      'category_id': 'cat',
      'name': 'حساب $id',
      'currency_code': currency,
      'opening_minor': opening,
      'opening_type': type,
      'phone': phone,
      'created_at': 1,
      'updated_at': 1,
    });
    await account('a-yer', 'YER', opening: 5000, type: 'DEBIT', phone: '0530882752');
    await account('a-sar', 'SAR', opening: 300, type: 'CREDIT');
    await account('a-usd', 'USD');
    await account('a-odd', 'YER', opening: 0, type: 'DEBIT');

    Future<void> tx(
      String id,
      String number,
      String account,
      String type,
      int amount,
      String date,
      int balanceAfter, {
      int? deletedAt,
      String? walletId,
      String? walletEffect,
      String? paymentMethod,
    }) => txn.insert('book_transactions', <String, Object?>{
      'id': id,
      'transaction_number': number,
      'account_id': account,
      'type': type,
      'amount_minor': amount,
      'transaction_date': date,
      'balance_after': balanceAfter,
      'created_at': 1,
      'updated_at': 1,
      'deleted_at': deletedAt,
      'wallet_id': walletId,
      'wallet_effect': walletEffect,
      'payment_method': paymentMethod,
    });
    await tx('t1', 'TX-000001', 'a-yer', 'DEBIT', 1000, '2026-01-01', 6000,
        paymentMethod: 'cheque');
    await tx('t2', 'TX-000002', 'a-yer', 'CREDIT', 200, '2026-01-02', 5800);
    await tx('t3', 'TX-000003', 'a-yer', 'DEBIT', 999, '2026-01-03', 6799,
        deletedAt: 5);
    await tx('t4', 'TX-000004', 'a-sar', 'DEBIT', 100, '2026-01-04', -200,
        walletId: 'main-wallet', walletEffect: 'DECREASE');
    await txn.insert('wallet_transactions', <String, Object?>{
      'id': 'w1',
      'transaction_number': 'WTX-000001',
      'wallet_id': 'main-wallet',
      'currency_code': 'SAR',
      'type': 'linked',
      'direction': 'OUT',
      'amount_minor': 100,
      'balance_after': -100,
      'linked_book_transaction_id': 't4',
      'transaction_date': '2026-01-04',
      'created_at': 1,
      'updated_at': 1,
    });
    await txn.insert('wallet_balances', <String, Object?>{
      'wallet_id': 'main-wallet',
      'currency_code': 'SAR',
      'created_at': 1,
      'updated_at': 1,
    });
    await txn.insert('book_attachments', <String, Object?>{
      'id': 'att-1',
      'transaction_id': 't4',
      'kind': 'receipt',
      'file_name': 'سند.jpg',
      'mime_type': 'image/jpeg',
      'encrypted_file_name': 'enc-1.bin',
      'file_size': 10,
      'checksum': 'abc',
      'created_at': 1,
    });
    // The counters the app keeps in step with the numbers already handed out.
    await txn.insert('book_counters', <String, Object?>{'name': 'tx_number', 'value': 4},
        conflictAlgorithm: ConflictAlgorithm.replace);
    await txn.insert('book_counters', <String, Object?>{'name': 'wtx_number', 'value': 1},
        conflictAlgorithm: ConflictAlgorithm.replace);
    await txn.insert('book_audit_log', <String, Object?>{
      'id': 'log-1',
      'entity_type': 'transaction',
      'entity_id': 't1',
      'action': 'created',
      'details': 'TX-000001 DEBIT 1000',
      'created_at': 1,
    });
  }

  test('MigrationV14 is version 14', () {
    expect(const MigrationV14().version, 14);
    expect(AppDatabase.schemaVersion, greaterThanOrEqualTo(14));
  });

  test('a v13 database upgrades without losing a single row', () async {
    await createV13(seedBook);
    final app = AppDatabase(path: path);
    final db = await app.database;
    expect(await db.getVersion(), AppDatabase.schemaVersion);

    expect(await db.query('book_accounts'), hasLength(4));
    expect(await db.query('book_transactions'), hasLength(4));
    expect(await db.query('book_attachments'), hasLength(1));
    expect(await db.query('wallet_transactions'), hasLength(1));
    expect(await db.query('book_audit_log'), hasLength(1));
    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    expect(await db.rawQuery('PRAGMA integrity_check'), [
      {'integrity_check': 'ok'},
    ]);
    await app.close();
  });

  test('the account keeps its data but loses its currency and opening columns',
      () async {
    await createV13(seedBook);
    final app = AppDatabase(path: path);
    final db = await app.database;
    final columns = (await db.rawQuery('PRAGMA table_info(book_accounts)'))
        .map((row) => row['name'])
        .toSet();
    expect(
      columns,
      isNot(anyElement(anyOf('currency_code', 'opening_minor', 'opening_type'))),
    );
    expect(columns, containsAll(<String>['id', 'category_id', 'name', 'phone']));
    final yer = (await db.query('book_accounts', where: "id = 'a-yer'")).single;
    expect(yer['name'], 'حساب a-yer');
    expect(yer['phone'], '0530882752');
    await app.close();
  });

  test('every account gets one opening row in its old currency and side',
      () async {
    await createV13(seedBook);
    final app = AppDatabase(path: path);
    final db = await app.database;
    final rows = {
      for (final row in await db.query('book_account_balances'))
        row['account_id']! as String: row,
    };
    expect(rows.keys, {'a-yer', 'a-sar', 'a-usd', 'a-odd'});
    expect(rows['a-yer']!['currency_code'], 'YER');
    expect(rows['a-yer']!['opening_minor'], 5000);
    expect(rows['a-yer']!['opening_type'], 'DEBIT');
    expect(rows['a-sar']!['currency_code'], 'SAR');
    expect(rows['a-sar']!['opening_minor'], 300);
    expect(rows['a-sar']!['opening_type'], 'CREDIT');
    expect(rows['a-usd']!['currency_code'], 'USD');
    expect(rows['a-usd']!['opening_minor'], 0);
    expect(rows['a-usd']!['opening_type'], 'ZERO');
    // An inconsistent row (a side but no amount) is normalised, not fatal.
    expect(rows['a-odd']!['opening_minor'], 0);
    expect(rows['a-odd']!['opening_type'], 'ZERO');
    await app.close();
  });

  test('every transaction carries its account\'s old currency and keeps '
      'everything else', () async {
    await createV13(seedBook);
    final app = AppDatabase(path: path);
    final db = await app.database;
    final rows = {
      for (final row in await db.query('book_transactions'))
        row['id']! as String: row,
    };
    expect(rows['t1']!['currency_code'], 'YER');
    expect(rows['t2']!['currency_code'], 'YER');
    expect(rows['t3']!['currency_code'], 'YER');
    expect(rows['t4']!['currency_code'], 'SAR');
    // Numbers, amounts, balances, soft delete, wallet link: untouched.
    expect(rows['t1']!['transaction_number'], 'TX-000001');
    expect(rows['t1']!['amount_minor'], 1000);
    expect(rows['t1']!['balance_after'], 6000);
    expect(rows['t2']!['balance_after'], 5800);
    expect(rows['t3']!['deleted_at'], 5);
    expect(rows['t4']!['wallet_id'], 'main-wallet');
    expect(rows['t4']!['wallet_effect'], 'DECREASE');
    // The legacy label column is kept (never read or written any more).
    expect(rows['t1']!['payment_method'], 'cheque');
    await app.close();
  });

  test('attachments and the wallet link still hang off their transaction',
      () async {
    await createV13(seedBook);
    final app = AppDatabase(path: path);
    final db = await app.database;
    final attachment = (await db.query('book_attachments')).single;
    expect(attachment['transaction_id'], 't4');
    expect(attachment['encrypted_file_name'], 'enc-1.bin');
    final movement = (await db.query('wallet_transactions')).single;
    expect(movement['linked_book_transaction_id'], 't4');
    expect(movement['currency_code'], 'SAR');
    // The RESTRICT link still protects the transaction ...
    await expectLater(
      db.delete('book_transactions', where: "id = 't4'"),
      throwsA(isA<DatabaseException>()),
    );
    // ... and once the movement is gone the attachment cascades with it.
    await db.delete('wallet_transactions', where: "id = 'w1'");
    await db.delete('book_transactions', where: "id = 't4'");
    expect(await db.query('book_attachments'), isEmpty);
    await app.close();
  });

  test('the new schema enforces its rules and has its indexes', () async {
    await createV13(seedBook);
    final app = AppDatabase(path: path);
    final db = await app.database;
    // currency_code is required and must be a real currency.
    await expectLater(
      db.insert('book_transactions', <String, Object?>{
        'id': 'bad',
        'transaction_number': 'TX-999999',
        'account_id': 'a-yer',
        'type': 'DEBIT',
        'amount_minor': 1,
        'transaction_date': '2026-02-01',
        'created_at': 1,
        'updated_at': 1,
      }),
      throwsA(isA<DatabaseException>()),
    );
    await expectLater(
      db.insert('book_transactions', <String, Object?>{
        'id': 'bad',
        'transaction_number': 'TX-999999',
        'account_id': 'a-yer',
        'currency_code': 'XXX',
        'type': 'DEBIT',
        'amount_minor': 1,
        'transaction_date': '2026-02-01',
        'created_at': 1,
        'updated_at': 1,
      }),
      throwsA(isA<DatabaseException>()),
    );
    // One opening per (account, currency).
    await expectLater(
      db.insert('book_account_balances', <String, Object?>{
        'account_id': 'a-yer',
        'currency_code': 'YER',
        'created_at': 1,
        'updated_at': 1,
      }),
      throwsA(isA<DatabaseException>()),
    );
    // A zero side needs a zero amount and vice versa.
    await expectLater(
      db.insert('book_account_balances', <String, Object?>{
        'account_id': 'a-yer',
        'currency_code': 'SAR',
        'opening_minor': 5,
        'opening_type': 'ZERO',
        'created_at': 1,
        'updated_at': 1,
      }),
      throwsA(isA<DatabaseException>()),
    );
    final indexes = {
      for (final row in await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index'",
      ))
        row['name']! as String,
    };
    expect(
      indexes,
      containsAll(<String>[
        'idx_book_accounts_category',
        'idx_book_account_balances_currency',
        'idx_book_tx_account_currency_date',
        'idx_book_tx_account_date',
        'idx_book_tx_account_type',
        'idx_book_tx_date',
        'idx_book_tx_currency',
        'idx_book_tx_wallet',
        'idx_book_attachments_tx',
        'idx_wtx_wallet_currency_date',
        'idx_wtx_linked',
        'idx_wtx_leg_group',
      ]),
    );
    await app.close();
  });

  test('deleting an account removes its opening rows (cascade)', () async {
    await createV13(seedBook);
    final app = AppDatabase(path: path);
    final db = await app.database;
    await db.delete('book_account_balances', where: "account_id = 'a-usd'");
    await db.delete('book_accounts', where: "id = 'a-usd'");
    expect(
      await db.query('book_account_balances', where: "account_id = 'a-usd'"),
      isEmpty,
    );
    await db.delete('book_accounts', where: "id = 'a-odd'");
    expect(
      await db.query('book_account_balances', where: "account_id = 'a-odd'"),
      isEmpty,
      reason: 'ON DELETE CASCADE',
    );
    await app.close();
  });

  test('the migrated book reads back with the same balances per currency',
      () async {
    await createV13(seedBook);
    final app = AppDatabase(path: path);
    final repository = SqliteBookRepository(app);

    final yer = (await repository.accountSummary('a-yer'))!;
    expect(yer.currencyCodes, ['YER']);
    final line = yer.totalsOf('YER')!;
    expect(line.debitMinor, 6000, reason: 'opening 5,000 + debit 1,000');
    expect(line.creditMinor, 200);
    expect(line.netMinor, 5800);
    expect(line.transactionCount, 2, reason: 'the deleted row is not counted');

    final sar = (await repository.accountSummary('a-sar'))!;
    expect(sar.totalsOf('SAR')!.netMinor, -200);
    expect(sar.totalsOf('SAR')!.side, BalanceSide.credit);

    // Declared but unused / inconsistent: not shown.
    expect((await repository.accountSummary('a-usd'))!.currencies, isEmpty);
    expect((await repository.accountSummary('a-odd'))!.currencies, isEmpty);

    // The stored running balances already agree with the per-currency rule.
    for (final id in ['a-yer', 'a-sar', 'a-usd', 'a-odd']) {
      expect(await repository.countBalanceMismatches(id), 0, reason: id);
    }
    final position = await repository.netPosition();
    expect(position.map((p) => p.currencyCode), ['SAR', 'YER']);
    await repository.dispose();
    await app.close();
  });

  test(
    'requirement 14: after the upgrade, the wallet side is just as '
    'consistent and both statements build from the migrated data',
    () async {
      await createV13(seedBook);
      final app = AppDatabase(path: path);
      final repository = SqliteBookRepository(app);
      final reports = BookReportBuilder(
        repository: repository,
        currencies: testCurrencyRegistry(),
      );

      // The wallet-side mirror of countBalanceMismatches (requirement 12)
      // agrees with the migrated `wallet_transactions` row too.
      expect(await repository.countWalletBalanceMismatches('main-wallet'), 0);
      final wallet = (await repository.walletSummary('main-wallet'))!;
      expect(wallet.balanceOf('SAR'), -100);

      // كشف الحساب for the account whose migrated row (t4) is wallet-linked.
      final accountReport = await reports.accountStatement('a-sar');
      expect(accountReport.rowCount, greaterThan(0));

      // كشف المحفظة for the wallet that row is linked to.
      final walletReport = await reports.walletStatement('main-wallet');
      expect(walletReport.rowCount, greaterThan(0));

      await repository.dispose();
      await app.close();
    },
  );

  test('after the upgrade one account takes transactions in every currency',
      () async {
    await createV13(seedBook);
    final app = AppDatabase(path: path);
    final repository = SqliteBookRepository(app);
    final currencies = testCurrencyRegistry();
    final transactions = TransactionsController(
      repository: repository,
      currencies: currencies,
    );

    // «a-yer» was a YER account; it can now also owe SAR and USD — but only
    // through a wallet that holds the currency. The main wallet holds YER and
    // SAR here; USD is refused until it is added explicitly.
    await expectLater(
      transactions.create(
        BookTransactionDraft(
          accountId: 'a-yer',
          currencyCode: 'USD',
          type: EntryType.debit,
          amountMinor: 50,
          date: '2026-02-01',
          walletId: 'main-wallet',
        ),
      ),
      throwsA(isA<ValidationException>()),
    );
    expect(
      (await repository.walletSummary('main-wallet'))!.currencies,
      isNot(contains('USD')),
      reason: 'a refused transaction adds no currency to the wallet',
    );
    await WalletsController(repository: repository, currencies: currencies)
        .update(
          'main-wallet',
          const WalletDraft(
            name: 'الصندوق الرئيسي',
            openings: [
              WalletOpeningDraft(currencyCode: 'YER'),
              WalletOpeningDraft(currencyCode: 'SAR'),
              WalletOpeningDraft(currencyCode: 'USD'),
            ],
          ),
        );
    for (final code in ['SAR', 'USD', 'YER']) {
      await transactions.create(
        BookTransactionDraft(
          accountId: 'a-yer',
          currencyCode: code,
          type: EntryType.debit,
          amountMinor: 50,
          date: '2026-02-01',
          walletId: 'main-wallet',
        ),
      );
    }
    final summary = (await repository.accountSummary('a-yer'))!;
    expect(summary.currencyCodes, ['SAR', 'USD', 'YER']);
    expect(summary.totalsOf('YER')!.netMinor, 5850);
    expect(summary.totalsOf('SAR')!.netMinor, 50);
    expect(summary.totalsOf('USD')!.netMinor, 50);
    expect(await repository.countBalanceMismatches('a-yer'), 0);

    // The wallet moved once per event, each in its own currency.
    final wallet = (await repository.walletSummary('main-wallet'))!;
    expect(wallet.balanceOf('SAR'), -150, reason: '-100 already there, -50 new');
    expect(wallet.balanceOf('USD'), -50);
    await repository.dispose();
    await app.close();
  });

  test('a snapshot of the v13 file is taken before the upgrade', () async {
    await createV13(seedBook);
    final app = AppDatabase(path: path);
    await app.database;
    expect(
      app.snapshotFileName,
      contains('.pre-v${AppDatabase.schemaVersion}-'),
    );
    await app.close();

    final snapshot = File(
      '${sandbox.path}${Platform.pathSeparator}${app.snapshotFileName}',
    );
    final raw = await openDatabase(snapshot.path, readOnly: true);
    expect(await raw.getVersion(), 13);
    final columns = (await raw.rawQuery('PRAGMA table_info(book_accounts)'))
        .map((row) => row['name'])
        .toSet();
    expect(columns, containsAll(<String>['currency_code', 'opening_minor']));
    expect(await raw.query('book_transactions'), hasLength(4));
    await raw.close();
  });

  test('an empty v13 database and a fresh install both reach v14 cleanly',
      () async {
    await createV13((_) async {});
    var app = AppDatabase(path: path);
    var db = await app.database;
    expect(await db.getVersion(), AppDatabase.schemaVersion);
    expect(await db.query('book_account_balances'), isEmpty);
    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    await app.close();

    final fresh = '${sandbox.path}${Platform.pathSeparator}fresh.sqlite';
    app = AppDatabase(path: fresh);
    db = await app.database;
    expect(await db.getVersion(), AppDatabase.schemaVersion);
    final tables = {
      for (final row in await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      ))
        row['name']! as String,
    };
    expect(tables, contains('book_account_balances'));
    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    await app.close();
  });
}
