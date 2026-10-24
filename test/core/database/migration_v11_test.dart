import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/core/database/app_database.dart';
import 'package:jibi/core/errors/app_exception.dart';

/// Schema v11 adds the wallets/boxes feature: `wallets`,
/// `wallet_transactions`, and three new columns on `book_transactions`
/// (`wallet_id`, `wallet_effect`, `payment_method`). These tests start from a
/// real v10 file with a category, an account and a transaction already in it.
void main() {
  late Directory sandbox;
  late String path;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('jibi_migration_v11_');
    path = '${sandbox.path}${Platform.pathSeparator}database.sqlite';
  });

  tearDown(() async {
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
  });

  const v10Migrations = <DatabaseMigration>[
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
  ];

  /// Builds a v10 database (foreign keys on, like the app) at [target] and
  /// seeds it.
  Future<void> createV10(
    Future<void> Function(Transaction txn) seed, {
    String? target,
  }) async {
    final legacy = await openDatabase(
      target ?? path,
      version: 10,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, version) => db.transaction((txn) async {
        for (final migration in v10Migrations) {
          await migration.apply(txn);
        }
        await seed(txn);
      }),
    );
    await legacy.close();
  }

  Future<void> seedBook(Transaction txn) async {
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
      'currency_code': 'SAR',
      'created_at': 1,
      'updated_at': 1,
    });
    await txn.insert('book_transactions', <String, Object?>{
      'id': 'tx',
      'transaction_number': 'TX-000001',
      'account_id': 'acc',
      'type': 'DEBIT',
      'amount_minor': 500,
      'transaction_date': '2025-01-05',
      'balance_after': 500,
      'created_at': 1,
      'updated_at': 1,
    });
  }

  // `AppDatabase(path: path)` always migrates to the current
  // `AppDatabase.schemaVersion`, not to 11 specifically — later schema
  // versions (v12: multi-currency wallets) can and do further reshape what
  // MigrationV11 created, so these tests check what survives through to
  // today rather than v11's exact intermediate shape. See
  // `migration_v12_test.dart` for the wallet-currency shape as it is now.
  test('MigrationV11 is version 11', () {
    expect(const MigrationV11().version, 11);
    expect(AppDatabase.schemaVersion, greaterThanOrEqualTo(11));
  });

  test('a fresh install seeds exactly one main wallet', () async {
    final app = AppDatabase(path: path);
    final db = await app.database;
    expect(await db.getVersion(), AppDatabase.schemaVersion);

    final wallets = await db.query('wallets');
    expect(wallets, hasLength(1));
    final main = wallets.single;
    expect(main['id'], MigrationV11.mainWalletId);
    expect(main['name'], MigrationV11.mainWalletName);
    expect(main['is_main'], 1);
    expect(main['status'], 'active');

    final columns = await db.rawQuery('PRAGMA table_info(book_transactions)');
    final names = columns.map((row) => row['name']).toSet();
    expect(names, containsAll(<String>['wallet_id', 'wallet_effect', 'payment_method']));
    await app.close();
  });

  test('upgrading a v10 database keeps its data and adds the wallet tables',
      () async {
    await createV10(seedBook);
    final app = AppDatabase(path: path);
    final db = await app.database;
    expect(await db.getVersion(), AppDatabase.schemaVersion);

    final wallets = await db.query('wallets');
    expect(wallets, hasLength(1));
    expect(wallets.single['is_main'], 1);

    expect(await db.query('wallet_transactions'), isEmpty);

    // The book is exactly as it was.
    expect(await db.query('book_categories'), hasLength(1));
    expect((await db.query('book_accounts')).single['name'], 'علي');
    final tx = (await db.query('book_transactions')).single;
    expect(tx['amount_minor'], 500);
    expect(tx['balance_after'], 500);
    expect(tx['wallet_id'], isNull);
    expect(tx['wallet_effect'], isNull);
    expect(tx['payment_method'], isNull);

    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    expect(
      (await db.rawQuery('PRAGMA integrity_check')).single.values.single,
      'ok',
    );
    await app.close();
  });

  // The next two tests exercise invariants of the *current* wallet schema
  // (v12: currency lives on `wallet_balances`, not on `wallets`, and a
  // movement's group column is `leg_group_id`) rather than v11's own
  // intermediate shape — see the module doc comment above.
  test('only one wallet can be flagged main at the database level', () async {
    final app = AppDatabase(path: path);
    final db = await app.database;
    await expectLater(
      db.insert('wallets', <String, Object?>{
        'id': 'second-main',
        'name': 'محفظة أخرى',
        'is_main': 1,
        'status': 'active',
        'sort_order': 1,
        'created_at': 1,
        'updated_at': 1,
      }),
      throwsA(isA<DatabaseException>()),
    );
    await app.close();
  });

  test(
    'a wallet movement needs its wallet, and a transfer needs a leg group',
    () async {
      final app = AppDatabase(path: path);
      final db = await app.database;
      final currency = (await db.query(
        'wallet_balances',
        columns: <String>['currency_code'],
        limit: 1,
      )).single['currency_code'];
      await db.insert('wallets', <String, Object?>{
        'id': 'w2',
        'name': 'محفظة بنكية',
        'is_main': 0,
        'status': 'active',
        'sort_order': 1,
        'created_at': 1,
        'updated_at': 1,
      });
      // A deposit (not a transfer/exchange) with a leg_group_id is rejected.
      await expectLater(
        db.insert('wallet_transactions', <String, Object?>{
          'id': 'bad',
          'transaction_number': 'WTX-000001',
          'wallet_id': 'w2',
          'currency_code': currency,
          'type': 'deposit',
          'direction': 'IN',
          'amount_minor': 1000,
          'leg_group_id': 'group-1',
          'transaction_date': '2025-01-01',
          'created_at': 1,
          'updated_at': 1,
        }),
        throwsA(isA<DatabaseException>()),
      );
      // A well-formed deposit is accepted.
      await db.insert('wallet_transactions', <String, Object?>{
        'id': 'good',
        'transaction_number': 'WTX-000001',
        'wallet_id': 'w2',
        'currency_code': currency,
        'type': 'deposit',
        'direction': 'IN',
        'amount_minor': 1000,
        'transaction_date': '2025-01-01',
        'created_at': 1,
        'updated_at': 1,
      });
      expect(await db.query('wallet_transactions'), hasLength(1));
      await app.close();
    },
  );

  test('a snapshot of the v10 file is taken before the wallet tables land',
      () async {
    await createV10(seedBook);
    final app = AppDatabase(path: path);
    await app.database;
    expect(app.snapshotFileName, contains('.pre-v${AppDatabase.schemaVersion}-'));
    await app.close();

    final snapshot = File(
      '${sandbox.path}${Platform.pathSeparator}${app.snapshotFileName}',
    );
    final raw = await openDatabase(snapshot.path, readOnly: true);
    expect(await raw.getVersion(), 10);
    final tables = await raw.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    expect(
      tables.map((row) => row['name']),
      isNot(contains('wallets')),
    );
    await raw.close();
  });

  test('an older database put in place (a restored backup) is upgraded',
      () async {
    final app = AppDatabase(path: path);
    expect(await (await app.database).getVersion(), AppDatabase.schemaVersion);
    await app.close();
    await File(path).delete();
    final older = '${sandbox.path}${Platform.pathSeparator}older.sqlite';
    await createV10(seedBook, target: older);
    await File(older).copy(path);

    final db = await app.database;
    expect(await db.getVersion(), AppDatabase.schemaVersion);
    expect(await db.query('wallets'), hasLength(1));
    expect((await db.query('book_accounts')).single['name'], 'علي');
    await app.close();
  });

  test('a failing migration rolls back and leaves version 10 intact',
      () async {
    await createV10((txn) async {
      await seedBook(txn);
      // A pre-existing "wallets" table makes MigrationV11's CREATE TABLE fail.
      await txn.execute('CREATE TABLE wallets (id TEXT)');
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
    expect(await raw.getVersion(), 10);
    await raw.close();
  });
}
