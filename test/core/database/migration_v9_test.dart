import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/core/database/app_database.dart';
import 'package:jibi/core/database/sqlite_jibi_repository.dart';
import 'package:jibi/core/errors/app_exception.dart';
import 'package:jibi/core/models/currency.dart';

/// Schema v9 removes the general expenses feature (`expenses` and
/// `expense_categories`). These tests start from a real v8 file full of
/// expenses and of everything that must survive.
void main() {
  late Directory sandbox;
  late String path;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('jibi_migration_v9_');
    path = '${sandbox.path}${Platform.pathSeparator}database.sqlite';
  });

  tearDown(() async {
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
  });

  const v8Migrations = <DatabaseMigration>[
    MigrationV1(),
    MigrationV2(),
    MigrationV3(),
    MigrationV4(),
    MigrationV5(),
    MigrationV6(),
    MigrationV7(),
    MigrationV8(),
  ];

  /// Builds a v8 database (foreign keys on, like the app) at [target] and
  /// seeds it.
  Future<void> createV8(
    Future<void> Function(Transaction txn) seed, {
    String? target,
  }) async {
    final legacy = await openDatabase(
      target ?? path,
      version: 8,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, version) => db.transaction((txn) async {
        for (final migration in v8Migrations) {
          await migration.apply(txn);
        }
        await seed(txn);
      }),
    );
    await legacy.close();
  }

  Future<Set<String>> tableNames(Database db) async => {
    for (final row in await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    ))
      row['name']! as String,
  };

  /// Two expenses (one with a file and its reference), an unrelated
  /// attachment reference, and everything the rest of the app owns.
  Future<void> seedEverything(Transaction txn) async {
    await txn.insert('documents', <String, Object?>{
      'id': 'doc',
      'title': 'Passport',
      'created_at': 1,
      'updated_at': 1,
    });
    for (final id in ['file-a', 'file-b']) {
      await txn.insert('document_files', <String, Object?>{
        'id': id,
        'document_id': 'doc',
        'encrypted_file_name': 'enc-$id',
        'original_extension': 'pdf',
        'mime_type': 'application/pdf',
        'encrypted_size': 10,
        'checksum': id,
        'created_at': 1,
      });
    }
    for (final expense in [
      ('plain', 1000, null),
      ('with-file', 3000, 'file-a'),
    ]) {
      await txn.insert('expenses', <String, Object?>{
        'id': expense.$1,
        'amount_minor': expense.$2,
        'currency_code': 'SAR',
        'category_id': 'home',
        'expense_date': 1700000000000,
        'title': 'title-${expense.$1}',
        'attachment_id': expense.$3,
        'created_at': 5,
        'updated_at': 6,
      });
    }
    await txn.insert('attachment_refs', <String, Object?>{
      'id': 'ref-expense',
      'owner_type': 'expense',
      'owner_id': 'with-file',
      'document_file_id': 'file-a',
      'created_at': 1,
    });
    await txn.insert('attachment_refs', <String, Object?>{
      'id': 'ref-other',
      'owner_type': 'other',
      'owner_id': 'somebody',
      'document_file_id': 'file-b',
      'created_at': 1,
    });
    await txn.insert('credentials', <String, Object?>{
      'id': 'cred',
      'title': 'Gmail',
      'username_encrypted': 'v1.a',
      'email_encrypted': 'v1.b',
      'password_encrypted': 'v1.c',
      'notes_encrypted': 'v1.d',
      'created_at': 1,
      'updated_at': 1,
    });
    await txn.insert('book_categories', <String, Object?>{
      'id': 'cat',
      'name': 'Friends',
      'created_at': 1,
      'updated_at': 1,
    });
    await txn.insert('book_accounts', <String, Object?>{
      'id': 'acc',
      'category_id': 'cat',
      'name': 'Ali',
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
    await txn.insert('book_attachments', <String, Object?>{
      'id': 'book-file',
      'transaction_id': 'tx',
      'file_name': 'receipt.pdf',
      'mime_type': 'application/pdf',
      'document_file_id': 'file-b',
      'created_at': 1,
    });
  }

  test('MigrationV9 is version 9', () {
    expect(const MigrationV9().version, 9);
  });

  test('a fresh install has no expense tables at all', () async {
    final app = AppDatabase(path: path);
    final db = await app.database;
    expect(await db.getVersion(), AppDatabase.schemaVersion);
    final tables = await tableNames(db);
    for (final table in MigrationV9.droppedTables) {
      expect(tables, isNot(contains(table)), reason: table);
    }
    // What the rest of the app relies on is still created.
    expect(
      tables,
      containsAll(<String>[
        'attachment_refs',
        'document_files',
        'book_accounts',
        'credentials',
        'currencies',
      ]),
    );
    await app.close();
  });

  test('drops the expense tables and keeps everything else', () async {
    await createV8(seedEverything);
    final app = AppDatabase(path: path);
    final db = await app.database;
    expect(await db.getVersion(), AppDatabase.schemaVersion);

    final tables = await tableNames(db);
    for (final table in MigrationV9.droppedTables) {
      expect(tables, isNot(contains(table)), reason: table);
    }
    // Their indexes and the cleanup trigger went with them.
    final leftovers = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE name LIKE '%expense%'",
    );
    expect(leftovers, isEmpty);

    // Only the expense's own reference is removed.
    expect(
      (await db.query('attachment_refs')).map((row) => row['id']),
      ['ref-other'],
    );
    // Files are never touched (the app never attached any to an expense).
    expect(await db.query('document_files'), hasLength(2));
    expect(await db.query('documents'), hasLength(1));
    expect(await db.query('credentials'), hasLength(1));

    // The book is exactly as it was.
    expect(await db.query('book_categories'), hasLength(1));
    expect((await db.query('book_accounts')).single['name'], 'Ali');
    final tx = (await db.query('book_transactions')).single;
    expect(tx['amount_minor'], 500);
    expect(tx['balance_after'], 500);
    expect(
      (await db.query('book_attachments')).single['document_file_id'],
      'file-b',
    );

    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    expect((await db.rawQuery('PRAGMA integrity_check')).single.values.single, 'ok');
    await app.close();
  });

  test('a snapshot of the v8 file is taken before the tables go', () async {
    await createV8(seedEverything);
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
    expect(await raw.getVersion(), 8);
    expect(await raw.query('expenses'), hasLength(2));
    expect(await raw.query('expense_categories'), hasLength(10));
    await raw.close();
  });

  test('the currency check reads only tables that still exist', () async {
    await createV8(seedEverything);
    final app = AppDatabase(path: path);
    final repository = SqliteJibiRepository(app);

    // SAR is used by a book account; the expense that also used it is gone.
    expect(await repository.isCurrencyUsed('SAR'), isTrue);
    // EUR was seeded but nothing uses it, so v13 already removed it; a fresh
    // unused currency shows the same rule.
    expect(await repository.findCurrency('EUR'), isNull);
    await repository.createCurrency(
      Currency(code: 'JPY', name: 'ين ياباني', fractionDigits: 0),
    );
    expect(await repository.isCurrencyUsed('JPY'), isFalse);
    await repository.deleteCurrency('JPY');
    await expectLater(
      repository.deleteCurrency('SAR'),
      throwsA(isA<ConflictException>()),
    );
    await repository.dispose();
    await app.close();
  });

  test('an older database put in place (a restored backup) is upgraded', () async {
    // A backup restore closes the database, replaces the file and reopens it.
    final app = AppDatabase(path: path);
    expect(
      await (await app.database).getVersion(),
      AppDatabase.schemaVersion,
    );
    await app.close();
    await File(path).delete();
    final older = '${sandbox.path}${Platform.pathSeparator}older.sqlite';
    await createV8(seedEverything, target: older);
    await File(older).copy(path);

    final db = await app.database;
    expect(await db.getVersion(), AppDatabase.schemaVersion);
    expect(await tableNames(db), isNot(contains('expenses')));
    expect((await db.query('book_accounts')).single['name'], 'Ali');
    expect(await db.query('credentials'), hasLength(1));
    await app.close();
  });

  test('a failing migration rolls back and leaves version 8 intact', () async {
    await createV8((txn) async {
      await seedEverything(txn);
      // Makes the migration's first statement (removing the expense's
      // attachment reference) fail.
      await txn.execute('''
        CREATE TRIGGER block_ref_delete BEFORE DELETE ON attachment_refs
        BEGIN SELECT RAISE(ABORT, 'blocked'); END
      ''');
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
    expect(await raw.getVersion(), 8);
    expect(await raw.query('expenses'), hasLength(2));
    expect(await raw.query('expense_categories'), hasLength(10));
    expect(await raw.query('attachment_refs'), hasLength(2));
    await raw.close();
  });
}
