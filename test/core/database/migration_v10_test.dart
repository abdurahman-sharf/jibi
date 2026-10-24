import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/core/database/app_database.dart';
import 'package:jibi/core/errors/app_exception.dart';

/// Schema v10 adds an optional `phone` column to `book_accounts`. These
/// tests start from a real v9 file with a category, an account and a
/// transaction already in it.
void main() {
  late Directory sandbox;
  late String path;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('jibi_migration_v10_');
    path = '${sandbox.path}${Platform.pathSeparator}database.sqlite';
  });

  tearDown(() async {
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
  });

  const v9Migrations = <DatabaseMigration>[
    MigrationV1(),
    MigrationV2(),
    MigrationV3(),
    MigrationV4(),
    MigrationV5(),
    MigrationV6(),
    MigrationV7(),
    MigrationV8(),
    MigrationV9(),
  ];

  /// Builds a v9 database (foreign keys on, like the app) at [target] and
  /// seeds it.
  Future<void> createV9(
    Future<void> Function(Transaction txn) seed, {
    String? target,
  }) async {
    final legacy = await openDatabase(
      target ?? path,
      version: 9,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, version) => db.transaction((txn) async {
        for (final migration in v9Migrations) {
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

  test('MigrationV10 is version 10', () {
    expect(const MigrationV10().version, 10);
  });

  test('a fresh install has the phone column', () async {
    final app = AppDatabase(path: path);
    final db = await app.database;
    expect(await db.getVersion(), AppDatabase.schemaVersion);
    final columns = await db.rawQuery('PRAGMA table_info(book_accounts)');
    expect(columns.map((row) => row['name']), contains('phone'));
    await app.close();
  });

  test('adds phone to book_accounts and keeps existing rows and data',
      () async {
    await createV9(seedBook);
    final app = AppDatabase(path: path);
    final db = await app.database;
    expect(await db.getVersion(), AppDatabase.schemaVersion);

    final columns = await db.rawQuery('PRAGMA table_info(book_accounts)');
    expect(columns.map((row) => row['name']), contains('phone'));

    final account = (await db.query('book_accounts')).single;
    expect(account['name'], 'علي');
    expect(account['phone'], isNull);

    await db.update(
      'book_accounts',
      <String, Object?>{'phone': '0530882752'},
      where: 'id = ?',
      whereArgs: <Object?>['acc'],
    );
    final updated = (await db.query('book_accounts')).single;
    expect(updated['phone'], '0530882752');

    // Nothing else moved.
    expect(await db.query('book_categories'), hasLength(1));
    final tx = (await db.query('book_transactions')).single;
    expect(tx['amount_minor'], 500);
    expect(tx['balance_after'], 500);

    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    expect(
      (await db.rawQuery('PRAGMA integrity_check')).single.values.single,
      'ok',
    );
    await app.close();
  });

  test('a snapshot of the v9 file is taken before the column is added',
      () async {
    await createV9(seedBook);
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
    expect(await raw.getVersion(), 9);
    final columns = await raw.rawQuery('PRAGMA table_info(book_accounts)');
    expect(columns.map((row) => row['name']), isNot(contains('phone')));
    await raw.close();
  });

  test('an older database put in place (a restored backup) is upgraded',
      () async {
    // A backup restore closes the database, replaces the file and reopens it.
    final app = AppDatabase(path: path);
    expect(
      await (await app.database).getVersion(),
      AppDatabase.schemaVersion,
    );
    await app.close();
    await File(path).delete();
    final older = '${sandbox.path}${Platform.pathSeparator}older.sqlite';
    await createV9(seedBook, target: older);
    await File(older).copy(path);

    final db = await app.database;
    expect(await db.getVersion(), AppDatabase.schemaVersion);
    final columns = await db.rawQuery('PRAGMA table_info(book_accounts)');
    expect(columns.map((row) => row['name']), contains('phone'));
    expect((await db.query('book_accounts')).single['name'], 'علي');
    await app.close();
  });

  test('a failing migration rolls back and leaves version 9 intact',
      () async {
    await createV9((txn) async {
      await seedBook(txn);
      // A column already named "phone" makes MigrationV10's ADD COLUMN fail.
      await txn.execute('ALTER TABLE book_accounts ADD COLUMN phone TEXT');
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
    expect(await raw.getVersion(), 9);
    await raw.close();
  });
}
