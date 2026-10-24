import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/core/database/app_database.dart';
import 'package:jibi/core/errors/app_exception.dart';

/// Schema v12 moves a wallet's currency off `wallets` and onto a
/// `wallet_balances` row per (wallet, currency), gives `wallet_transactions`
/// its own `currency_code`, adds the `exchange` type, and renames
/// `transfer_group_id` to `leg_group_id`. These tests start from a real v11
/// file with wallets, movements, a transfer, and a linked book transaction
/// already in it, and check that nothing is lost across the rebuild.
void main() {
  late Directory sandbox;
  late String path;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('jibi_migration_v12_');
    path = '${sandbox.path}${Platform.pathSeparator}database.sqlite';
  });

  tearDown(() async {
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
  });

  const v11Migrations = <DatabaseMigration>[
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
  ];

  /// Builds a v11 database (foreign keys on, like the app) at [target],
  /// including v11's own seeded main wallet, then lets [seed] add more.
  Future<void> createV11(
    Future<void> Function(Transaction txn) seed, {
    String? target,
  }) async {
    final legacy = await openDatabase(
      target ?? path,
      version: 11,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, version) => db.transaction((txn) async {
        for (final migration in v11Migrations) {
          await migration.apply(txn);
        }
        await seed(txn);
      }),
    );
    await legacy.close();
  }

  /// A second, SAR wallet ("w2"), a category/account/transaction in SAR, a
  /// deposit and a withdrawal on the main (YER) wallet, a transfer of the
  /// SAR wallet's money to the main wallet (cross-wallet, same currency in
  /// v11), and a book transaction linked to the SAR wallet.
  Future<void> seedWallets(Transaction txn) async {
    final main = (await txn.query(
      'wallets',
      columns: <String>['id', 'currency_code'],
      where: 'is_main = 1',
    )).single;
    final mainId = main['id']! as String;
    final mainCurrency = main['currency_code']! as String;

    await txn.insert('wallet_transactions', <String, Object?>{
      'id': 'dep-1',
      'transaction_number': 'WTX-000001',
      'wallet_id': mainId,
      'type': 'deposit',
      'direction': 'IN',
      'amount_minor': 100000,
      'balance_after': 100000,
      'transaction_date': '2026-01-01',
      'created_at': 1,
      'updated_at': 1,
    });
    await txn.insert('wallet_transactions', <String, Object?>{
      'id': 'wd-1',
      'transaction_number': 'WTX-000002',
      'wallet_id': mainId,
      'type': 'withdrawal',
      'direction': 'OUT',
      'amount_minor': 20000,
      'balance_after': 80000,
      'transaction_date': '2026-01-02',
      'created_at': 2,
      'updated_at': 2,
    });
    // A soft-deleted movement: still copied, still counted.
    await txn.insert('wallet_transactions', <String, Object?>{
      'id': 'wd-2',
      'transaction_number': 'WTX-000003',
      'wallet_id': mainId,
      'type': 'withdrawal',
      'direction': 'OUT',
      'amount_minor': 500,
      'balance_after': 79500,
      'transaction_date': '2026-01-03',
      'created_at': 3,
      'updated_at': 3,
      'deleted_at': 4,
    });

    await txn.insert('wallets', <String, Object?>{
      'id': 'w2',
      'name': 'محفظة بنكية',
      'wallet_type': 'bank',
      'is_main': 0,
      'currency_code': mainCurrency,
      'opening_minor': 5000,
      'status': 'active',
      'sort_order': 1,
      'created_at': 1,
      'updated_at': 1,
    });
    await txn.insert('wallet_transactions', <String, Object?>{
      'id': 'xfer-out',
      'transaction_number': 'WTX-000004',
      'wallet_id': 'w2',
      'type': 'transfer',
      'direction': 'OUT',
      'amount_minor': 3000,
      'balance_after': 2000,
      'transfer_group_id': 'group-1',
      'transaction_date': '2026-01-04',
      'created_at': 5,
      'updated_at': 5,
    });
    await txn.insert('wallet_transactions', <String, Object?>{
      'id': 'xfer-in',
      'transaction_number': 'WTX-000005',
      'wallet_id': mainId,
      'type': 'transfer',
      'direction': 'IN',
      'amount_minor': 3000,
      'balance_after': 82500,
      'transfer_group_id': 'group-1',
      'transaction_date': '2026-01-04',
      'created_at': 5,
      'updated_at': 5,
    });

    await txn.insert('book_categories', <String, Object?>{
      'id': 'cat',
      'name': 'الأصدقاء',
      'created_at': 1,
      'updated_at': 1,
    });
    await txn.insert('book_accounts', <String, Object?>{
      'id': 'acc',
      'category_id': 'cat',
      'name': 'علي',
      'currency_code': mainCurrency,
      'created_at': 1,
      'updated_at': 1,
    });
    await txn.insert('book_transactions', <String, Object?>{
      'id': 'tx-linked',
      'transaction_number': 'TX-000001',
      'account_id': 'acc',
      'type': 'DEBIT',
      'amount_minor': 1000,
      'transaction_date': '2026-01-05',
      'balance_after': 1000,
      'wallet_id': mainId,
      'wallet_effect': 'DECREASE',
      'created_at': 1,
      'updated_at': 1,
    });
    await txn.insert('wallet_transactions', <String, Object?>{
      'id': 'linked-1',
      'transaction_number': 'WTX-000006',
      'wallet_id': mainId,
      'type': 'linked',
      'direction': 'OUT',
      'amount_minor': 1000,
      'balance_after': 81500,
      'linked_book_transaction_id': 'tx-linked',
      'transaction_date': '2026-01-05',
      'created_at': 6,
      'updated_at': 6,
    });
  }

  test('MigrationV12 is version 12', () {
    expect(const MigrationV12().version, 12);
    expect(AppDatabase.schemaVersion, greaterThanOrEqualTo(12));
  });

  test(
    'upgrading a v11 database rebuilds the wallet tables without losing rows',
    () async {
      await createV11(seedWallets);
      final before = await openDatabase(path, readOnly: true);
      final beforeWalletCount = (await before.query('wallets')).length;
      final beforeMovementCount =
          (await before.query('wallet_transactions')).length;
      final beforeBookTxCount = (await before.query('book_transactions')).length;
      await before.close();

      final app = AppDatabase(path: path);
      final db = await app.database;
      expect(await db.getVersion(), AppDatabase.schemaVersion);

      // No wallet or movement was dropped.
      expect(await db.query('wallets'), hasLength(beforeWalletCount));
      expect(
        await db.query('wallet_transactions'),
        hasLength(beforeMovementCount),
      );
      expect(
        await db.query('book_transactions'),
        hasLength(beforeBookTxCount),
      );

      // `wallets` no longer carries the old columns.
      final walletColumns = (await db.rawQuery('PRAGMA table_info(wallets)'))
          .map((row) => row['name'])
          .toSet();
      expect(
        walletColumns,
        isNot(anyElement(anyOf('wallet_type', 'currency_code', 'opening_minor'))),
      );
      expect(
        walletColumns,
        containsAll(<String>['id', 'name', 'is_main', 'status']),
      );

      // One wallet_balances row per old wallet, with its old currency and
      // opening balance intact.
      final balances = await db.query('wallet_balances');
      expect(balances, hasLength(beforeWalletCount));
      final w2Balance = balances.singleWhere(
        (row) => row['wallet_id'] == 'w2',
      );
      expect(w2Balance['opening_minor'], 5000);
      expect(w2Balance['currency_code'], isNotNull);

      // Every movement kept its id, number and balance_after, and gained the
      // right currency_code (its old wallet's single currency).
      final walletCurrency = w2Balance['currency_code'];
      final mainCurrency = (await db.query(
        'wallet_balances',
        where: 'wallet_id != ?',
        whereArgs: ['w2'],
        limit: 1,
      )).single['currency_code'];
      final xferOut = (await db.query(
        'wallet_transactions',
        where: 'id = ?',
        whereArgs: ['xfer-out'],
      )).single;
      expect(xferOut['transaction_number'], 'WTX-000004');
      expect(xferOut['balance_after'], 2000);
      expect(xferOut['currency_code'], walletCurrency);
      // transfer_group_id became leg_group_id.
      expect(xferOut['leg_group_id'], 'group-1');
      expect(xferOut.containsKey('transfer_group_id'), isFalse);

      final deposit = (await db.query(
        'wallet_transactions',
        where: 'id = ?',
        whereArgs: ['dep-1'],
      )).single;
      expect(deposit['currency_code'], mainCurrency);
      expect(deposit['balance_after'], 100000);

      // The soft-deleted movement survived too.
      final softDeleted = (await db.query(
        'wallet_transactions',
        where: 'id = ?',
        whereArgs: ['wd-2'],
      )).single;
      expect(softDeleted['deleted_at'], 4);

      // book_transactions.wallet_id was detached and restored.
      final linkedTx = (await db.query(
        'book_transactions',
        where: 'id = ?',
        whereArgs: ['tx-linked'],
      )).single;
      expect(linkedTx['wallet_id'], isNotNull);
      expect(linkedTx['wallet_effect'], 'DECREASE');

      // No scaffolding tables left behind.
      final tables = (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      )).map((row) => row['name']).toSet();
      expect(tables, isNot(anyElement(startsWith('_v12_'))));

      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      expect(
        (await db.rawQuery('PRAGMA integrity_check')).single.values.single,
        'ok',
      );
      await app.close();
    },
  );

  test('the single unique-main index survives the rebuild', () async {
    await createV11(seedWallets);
    final app = AppDatabase(path: path);
    final db = await app.database;
    await expectLater(
      db.insert('wallets', <String, Object?>{
        'id': 'second-main',
        'name': 'محفظة أخرى',
        'is_main': 1,
        'status': 'active',
        'sort_order': 2,
        'created_at': 1,
        'updated_at': 1,
      }),
      throwsA(isA<DatabaseException>()),
    );
    await app.close();
  });

  test('the new exchange type is accepted and needs a leg group', () async {
    await createV11(seedWallets);
    final app = AppDatabase(path: path);
    final db = await app.database;
    final wallet = (await db.query('wallets', limit: 1)).single;
    final currency = (await db.query(
      'wallet_balances',
      where: 'wallet_id = ?',
      whereArgs: [wallet['id']],
      columns: <String>['currency_code'],
    )).first['currency_code'];

    // An exchange leg without a leg_group_id is rejected.
    await expectLater(
      db.insert('wallet_transactions', <String, Object?>{
        'id': 'ex-bad',
        'transaction_number': 'WTX-900001',
        'wallet_id': wallet['id'],
        'currency_code': currency,
        'type': 'exchange',
        'direction': 'OUT',
        'amount_minor': 100,
        'transaction_date': '2026-02-01',
        'created_at': 1,
        'updated_at': 1,
      }),
      throwsA(isA<DatabaseException>()),
    );
    // A well-formed exchange leg is accepted.
    await db.insert('wallet_transactions', <String, Object?>{
      'id': 'ex-good',
      'transaction_number': 'WTX-900002',
      'wallet_id': wallet['id'],
      'currency_code': currency,
      'type': 'exchange',
      'direction': 'OUT',
      'amount_minor': 100,
      'leg_group_id': 'ex-group-1',
      'transaction_date': '2026-02-01',
      'created_at': 1,
      'updated_at': 1,
    });
    expect(
      await db.query(
        'wallet_transactions',
        where: 'id = ?',
        whereArgs: ['ex-good'],
      ),
      hasLength(1),
    );
    await app.close();
  });

  test('a snapshot of the v11 file is taken before the rebuild', () async {
    await createV11(seedWallets);
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
    expect(await raw.getVersion(), 11);
    final columns = (await raw.rawQuery('PRAGMA table_info(wallets)'))
        .map((row) => row['name'])
        .toSet();
    expect(columns, contains('currency_code'));
    await raw.close();
  });

  test('a failing migration rolls back and leaves version 11 intact',
      () async {
    await createV11((txn) async {
      await seedWallets(txn);
      // A pre-existing scaffolding table makes MigrationV12's first CREATE
      // TABLE fail.
      await txn.execute('CREATE TABLE _v12_book_wallet (id TEXT)');
    });
    final app = AppDatabase(path: path);
    await expectLater(
      app.database,
      throwsA(
        isA<StorageException>().having(
          (error) => error.code,
          'code',
          'database_migration_failed',
        ),
      ),
    );
    expect(app.snapshotFileName, isNotNull);
    await app.close();

    final raw = await openDatabase(path, readOnly: true);
    expect(await raw.getVersion(), 11);
    // The original data is untouched.
    expect(await raw.query('wallets'), hasLength(2));
    final columns = (await raw.rawQuery('PRAGMA table_info(wallets)'))
        .map((row) => row['name'])
        .toSet();
    expect(columns, contains('currency_code'));
    await raw.close();
  });
}
