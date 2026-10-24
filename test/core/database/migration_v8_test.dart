import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/core/database/app_database.dart';
import 'package:jibi/core/errors/app_exception.dart';

/// Schema v8 drops the old accounts and wallets tables and rebuilds `expenses`
/// without its family columns. These tests start from a real v7 file that is
/// full of the data v8 removes and of the data it must keep.
///
/// Schema v9 later removed the expenses themselves (see `migration_v9_test`),
/// so the v8 behaviour is exercised by running `MigrationV8` alone (as the
/// 1.7.0 app did); the tests that go through [AppDatabase] check the current
/// end state.
void main() {
  late Directory sandbox;
  late String path;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('jibi_migration_v8_');
    path = '${sandbox.path}${Platform.pathSeparator}database.sqlite';
  });

  tearDown(() async {
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
  });

  /// Runs only [MigrationV8] on the v7 file, the way the app did at 1.7.0.
  Future<Database> upgradeToV8() => openDatabase(
    path,
    version: 8,
    onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
    onUpgrade: (db, from, to) =>
        db.transaction((txn) => const MigrationV8().apply(txn)),
  );

  /// Builds a v7 database (foreign keys on, like the app) and seeds it.
  Future<void> createV7(
    Future<void> Function(Transaction txn) seed,
  ) async {
    final legacy = await openDatabase(
      path,
      version: 7,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, version) => db.transaction((txn) async {
        for (final migration in const <DatabaseMigration>[
          MigrationV1(),
          MigrationV2(),
          MigrationV3(),
          MigrationV4(),
          MigrationV5(),
          MigrationV6(),
          MigrationV7(),
        ]) {
          await migration.apply(txn);
        }
        await seed(txn);
      }),
    );
    await legacy.close();
  }

  const droppedTables = <String>[
    'personal_accounts',
    'ledger_entries',
    'wallets',
    'persons',
    'wallet_transactions',
    'advances',
    'debts',
    'advance_payments',
    'debt_payments',
  ];

  Future<Set<String>> tableNames(Database db) async => {
    for (final row in await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    ))
      row['name']! as String,
  };

  Future<Set<String>> columnNames(Database db, String table) async => {
    for (final row in await db.rawQuery('PRAGMA table_info($table)'))
      row['name']! as String,
  };

  Future<void> expense(
    Transaction txn,
    String id,
    int amount, {
    String? accountId,
    String kind = 'general',
    String? attachmentId,
    String category = 'home',
  }) => txn.insert('expenses', <String, Object?>{
    'id': id,
    'amount_minor': amount,
    'currency_code': 'SAR',
    'category_id': category,
    'expense_date': 1700000000000,
    'title': 'title-$id',
    'notes': 'notes-$id',
    'attachment_id': attachmentId,
    'account_id': accountId,
    'expense_kind': kind,
    'created_at': 5,
    'updated_at': 6,
  });

  /// Everything the old features owned, plus expenses (family and ordinary,
  /// with and without an attachment) and a small book.
  Future<void> seedEverything(Transaction txn) async {
    await txn.insert('documents', <String, Object?>{
      'id': 'doc',
      'title': 'Passport',
      'created_at': 1,
      'updated_at': 1,
    });
    await txn.insert('document_files', <String, Object?>{
      'id': 'file-expense',
      'document_id': 'doc',
      'encrypted_file_name': 'enc-expense',
      'original_extension': 'pdf',
      'mime_type': 'application/pdf',
      'encrypted_size': 10,
      'checksum': 'x',
      'created_at': 1,
    });
    await txn.insert('document_files', <String, Object?>{
      'id': 'file-ledger',
      'document_id': 'doc',
      'encrypted_file_name': 'enc-ledger',
      'original_extension': 'pdf',
      'mime_type': 'application/pdf',
      'encrypted_size': 10,
      'checksum': 'y',
      'created_at': 1,
    });

    // Old accounts and their ledger, one entry with an attachment.
    await txn.insert('personal_accounts', <String, Object?>{
      'id': 'old-account',
      'name': 'علي',
      'created_at': 1,
      'updated_at': 1,
    });
    await txn.insert('ledger_entries', <String, Object?>{
      'id': 'old-entry',
      'account_id': 'old-account',
      'entry_type': 'loanGiven',
      'amount_minor': 500,
      'currency_code': 'SAR',
      'transaction_date': 1700000000000,
      'attachment_id': 'file-ledger',
      'created_at': 1,
      'updated_at': 1,
    });
    await txn.insert('attachment_refs', <String, Object?>{
      'id': 'ref-ledger',
      'owner_type': 'ledger_entry',
      'owner_id': 'old-entry',
      'document_file_id': 'file-ledger',
      'created_at': 1,
    });

    // Expenses: ordinary, family (linked to the old account), with attachment.
    await expense(txn, 'plain', 1000);
    await expense(txn, 'family', 2000, accountId: 'old-account', kind: 'family');
    await expense(txn, 'with-file', 3000, attachmentId: 'file-expense');
    await txn.insert('attachment_refs', <String, Object?>{
      'id': 'ref-expense',
      'owner_type': 'expense',
      'owner_id': 'with-file',
      'document_file_id': 'file-expense',
      'created_at': 1,
    });

    // The unified ledger: wallets, people, advances, debts and their payments.
    await txn.insert('wallets', <String, Object?>{
      'id': 'wallet',
      'name': 'Cash',
      'type': 'cash',
      'currency_code': 'SAR',
      'created_at': 1,
      'updated_at': 1,
    });
    await txn.insert('persons', <String, Object?>{
      'id': 'person',
      'name': 'Sami',
      'created_at': 1,
      'updated_at': 1,
    });
    await txn.insert('advances', <String, Object?>{
      'id': 'advance',
      'person_id': 'person',
      'src_wallet_id': 'wallet',
      'total_minor': 1000,
      'currency_code': 'SAR',
      'created_at': 1,
      'updated_at': 1,
    });
    await txn.insert('debts', <String, Object?>{
      'id': 'debt',
      'person_id': 'person',
      'dest_wallet_id': 'wallet',
      'total_minor': 800,
      'currency_code': 'SAR',
      'created_at': 1,
      'updated_at': 1,
    });
    await txn.insert('advance_payments', <String, Object?>{
      'id': 'advance-payment',
      'advance_id': 'advance',
      'amount_minor': 100,
      'wallet_id': 'wallet',
      'occurred_at': 1,
      'created_at': 1,
    });
    await txn.insert('debt_payments', <String, Object?>{
      'id': 'debt-payment',
      'debt_id': 'debt',
      'amount_minor': 100,
      'wallet_id': 'wallet',
      'occurred_at': 1,
      'created_at': 1,
    });
    await txn.insert('wallet_transactions', <String, Object?>{
      'id': 'wallet-tx',
      'type': 'expense',
      'amount_minor': 50,
      'currency_code': 'SAR',
      'wallet_id': 'wallet',
      'person_id': 'person',
      'occurred_at': 1,
      'created_at': 1,
      'updated_at': 1,
    });

    // The book, which must come through untouched.
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
      'legacy_account_id': 'old-account',
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
      'document_file_id': 'file-ledger',
      'created_at': 1,
    });
  }

  test('MigrationV8 is version 8 and the schema has moved past it', () {
    expect(const MigrationV8().version, 8);
    expect(AppDatabase.schemaVersion, greaterThanOrEqualTo(8));
  });

  test('a fresh install has none of the old tables', () async {
    final app = AppDatabase(path: path);
    final db = await app.database;
    expect(await db.getVersion(), AppDatabase.schemaVersion);
    final tables = await tableNames(db);
    // Schema v11 (the wallets/boxes feature) later reintroduced tables named
    // `wallets` and `wallet_transactions` for an unrelated new feature, with
    // a completely different shape from the v5 ones dropped here — so a
    // fresh install legitimately has them again. Every other name in
    // droppedTables must still never come back.
    for (final table in droppedTables) {
      if (table == 'wallets' || table == 'wallet_transactions') continue;
      expect(tables, isNot(contains(table)), reason: table);
    }
    // Expenses went in v9; the attachment references stay.
    expect(tables, contains('attachment_refs'));
    expect(tables, isNot(contains('expenses')));
    await app.close();
  });

  test('drops the old tables and keeps everything else', () async {
    await createV7(seedEverything);
    final db = await upgradeToV8();
    expect(await db.getVersion(), 8);

    final tables = await tableNames(db);
    for (final table in droppedTables) {
      expect(tables, isNot(contains(table)), reason: table);
    }

    // Every expense survives, family ones included (now ordinary).
    final expenses = await db.query('expenses', orderBy: 'id');
    expect(expenses.map((row) => row['id']), ['family', 'plain', 'with-file']);
    expect(expenses.map((row) => row['amount_minor']), [2000, 1000, 3000]);
    final family = expenses.first;
    expect(family['title'], 'title-family');
    expect(family['notes'], 'notes-family');
    expect(family['category_id'], 'home');
    expect(family['expense_date'], 1700000000000);
    expect(family['created_at'], 5);
    expect(family['updated_at'], 6);
    expect(expenses.last['attachment_id'], 'file-expense');
    expect(await columnNames(db, 'expenses'), isNot(contains('account_id')));
    expect(await columnNames(db, 'expenses'), isNot(contains('expense_kind')));

    // Expense attachments stay; the ledger's are gone; files are never touched.
    final refs = await db.query('attachment_refs');
    expect(refs.map((row) => row['id']), ['ref-expense']);
    expect(await db.query('document_files'), hasLength(2));
    expect(await db.query('documents'), hasLength(1));

    // The book is exactly as it was, with its attachment on the same file.
    expect(await db.query('book_categories'), hasLength(1));
    expect(await db.query('book_accounts'), hasLength(1));
    final tx = (await db.query('book_transactions')).single;
    expect(tx['amount_minor'], 500);
    expect(tx['balance_after'], 500);
    expect(
      (await db.query('book_attachments')).single['document_file_id'],
      'file-ledger',
    );

    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    expect((await db.rawQuery('PRAGMA integrity_check')).single.values.single, 'ok');
    await db.close();
  });

  test('a snapshot of the v7 file is taken before the tables go', () async {
    await createV7(seedEverything);
    final app = AppDatabase(path: path);
    await app.database;
    expect(app.snapshotFileName, contains('.pre-v${AppDatabase.schemaVersion}-'));
    await app.close();

    final snapshot = File(
      '${sandbox.path}${Platform.pathSeparator}${app.snapshotFileName}',
    );
    final raw = await openDatabase(snapshot.path, readOnly: true);
    expect(await raw.getVersion(), 7);
    expect(await raw.query('personal_accounts'), hasLength(1));
    expect(await raw.query('wallets'), hasLength(1));
    expect(await raw.query('ledger_entries'), hasLength(1));
    await raw.close();
  });

  test('expenses keep working after the rebuild', () async {
    await createV7(seedEverything);
    final db = await upgradeToV8();

    // Write, change and delete: a stale foreign key to a dropped table would
    // fail every one of these.
    await db.insert('expenses', <String, Object?>{
      'id': 'new',
      'amount_minor': 700,
      'currency_code': 'SAR',
      'category_id': 'food',
      'expense_date': 1,
      'created_at': 1,
      'updated_at': 1,
    });
    await db.update(
      'expenses',
      <String, Object?>{'amount_minor': 900},
      where: 'id = ?',
      whereArgs: <Object?>['new'],
    );
    expect(
      (await db.query('expenses', where: 'id = ?', whereArgs: <Object?>['new']))
          .single['amount_minor'],
      900,
    );

    // The cleanup trigger was recreated: deleting the expense drops its ref.
    await db.delete(
      'expenses',
      where: 'id = ?',
      whereArgs: <Object?>['with-file'],
    );
    expect(
      await db.query(
        'attachment_refs',
        where: 'owner_id = ?',
        whereArgs: <Object?>['with-file'],
      ),
      isEmpty,
    );
    expect(await db.query('expenses'), hasLength(3));
    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    await db.close();
  });

  test('the indexes and the trigger of expenses exist once', () async {
    await createV7(seedEverything);
    final db = await upgradeToV8();
    final names = {
      for (final row in await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE tbl_name = 'expenses'",
      ))
        row['name']! as String,
    };
    expect(names, contains('idx_expenses_date'));
    expect(names, contains('cleanup_expense_attachment_refs'));
    expect(names, isNot(contains('idx_expenses_account')));
    final leftovers = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE name LIKE 'cleanup_ledger%'",
    );
    expect(leftovers, isEmpty);
    await db.close();
  });

  test('upgrading straight from v6 ends at the current schema with the book filled', () async {
    final legacy = await openDatabase(
      path,
      version: 6,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, version) => db.transaction((txn) async {
        for (final migration in const <DatabaseMigration>[
          MigrationV1(),
          MigrationV2(),
          MigrationV3(),
          MigrationV4(),
          MigrationV5(),
          MigrationV6(),
        ]) {
          await migration.apply(txn);
        }
        await txn.insert('personal_accounts', <String, Object?>{
          'id': 'a1',
          'name': 'علي',
          'created_at': 1,
          'updated_at': 1,
        });
        await txn.insert('ledger_entries', <String, Object?>{
          'id': 'e1',
          'account_id': 'a1',
          'entry_type': 'loanGiven',
          'amount_minor': 100,
          'currency_code': 'SAR',
          'transaction_date': DateTime(2025, 1, 5).toUtc().millisecondsSinceEpoch,
          'created_at': 1,
          'updated_at': 1,
        });
        await expense(txn, 'family', 2000, accountId: 'a1', kind: 'family');
      }),
    );
    await legacy.close();

    final app = AppDatabase(path: path);
    final db = await app.database;
    expect(await db.getVersion(), AppDatabase.schemaVersion);
    // V7 copied the account and its entry, V8 then removed the originals.
    expect((await db.query('book_accounts')).single['name'], 'علي');
    final tx = (await db.query('book_transactions')).single;
    expect(tx['id'], 'e1');
    expect(tx['amount_minor'], 100);
    expect(await tableNames(db), isNot(contains('ledger_entries')));
    // The expense the old account carried went with the feature (v9).
    expect(await tableNames(db), isNot(contains('expenses')));
    await app.close();
  });

  test('a failing migration rolls back and leaves version 7 intact', () async {
    await createV7((txn) async {
      await seedEverything(txn);
      // A colliding table makes MigrationV8's CREATE TABLE fail.
      await txn.execute('CREATE TABLE expenses_new (id TEXT)');
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
    expect(await raw.getVersion(), 7);
    expect(await raw.query('personal_accounts'), hasLength(1));
    expect(await raw.query('wallets'), hasLength(1));
    expect(await raw.query('expenses'), hasLength(3));
    expect(await columnNames(raw, 'expenses'), contains('account_id'));
    await raw.close();
  });
}
