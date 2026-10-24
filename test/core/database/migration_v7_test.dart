import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/core/database/app_database.dart';
import 'package:jibi/core/errors/app_exception.dart';

int _utc(int y, int m, int d, [int h = 0, int min = 0]) =>
    DateTime(y, m, d, h, min).toUtc().millisecondsSinceEpoch;

void main() {
  late Directory sandbox;
  late String path;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('jibi_migration_v7_');
    path = '${sandbox.path}${Platform.pathSeparator}database.sqlite';
  });

  tearDown(() async {
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
  });

  Future<void> createV6(
    Future<void> Function(Transaction txn) seed,
  ) async {
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
        await seed(txn);
      }),
    );
    await legacy.close();
  }

  Future<void> account(
    Transaction txn,
    String id,
    String name, {
    String? phone,
    String? notes,
    bool archived = false,
    int createdAt = 1,
  }) => txn.insert('personal_accounts', <String, Object?>{
    'id': id,
    'name': name,
    'phone': phone,
    'notes': notes,
    'is_archived': archived ? 1 : 0,
    'created_at': createdAt,
    'updated_at': createdAt,
  });

  Future<void> entry(
    Transaction txn,
    String id,
    String accountId,
    String type,
    int amount,
    String currency,
    int when, {
    String? notes,
    String? attachmentId,
    int createdAt = 1,
  }) => txn.insert('ledger_entries', <String, Object?>{
    'id': id,
    'account_id': accountId,
    'entry_type': type,
    'amount_minor': amount,
    'currency_code': currency,
    'transaction_date': when,
    'notes': notes,
    'attachment_id': attachmentId,
    'created_at': createdAt,
    'updated_at': createdAt,
  });

  test('MigrationV7 exists and the schema has moved past it', () {
    expect(const MigrationV7().version, 7);
    expect(AppDatabase.schemaVersion, greaterThanOrEqualTo(7));
  });

  test('fresh install creates the book tables and seeds YER only', () async {
    final app = AppDatabase(path: path);
    final db = await app.database;
    expect(await db.getVersion(), AppDatabase.schemaVersion);
    for (final table in const [
      'book_categories',
      'book_accounts',
      'book_transactions',
      'book_attachments',
      'book_audit_log',
      'book_counters',
    ]) {
      final rows = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
        <Object?>[table],
      );
      expect(rows, hasLength(1), reason: table);
    }
    final yer = await db.query(
      'currencies',
      where: 'code = ?',
      whereArgs: ['YER'],
    );
    expect(yer.single['fraction_digits'], 0);
    expect(yer.single['is_active'], 1);
    expect(await db.query('book_categories'), isEmpty);
    expect(await db.query('book_accounts'), isEmpty);
    await app.close();
  });

  test('upgrade with no legacy accounts creates no category', () async {
    await createV6((txn) async {});
    final app = AppDatabase(path: path);
    final db = await app.database;
    expect(await db.getVersion(), AppDatabase.schemaVersion);
    expect(await db.query('book_categories'), isEmpty);
    await app.close();
  });

  test(
    'copies legacy accounts x currencies into an active category and keeps '
    'every signed balance',
    () async {
      await createV6((txn) async {
        await txn.insert('app_settings', <String, Object?>{
          'key': 'settings_v1',
          'value': '{"defaultCurrencyCode":"YER"}',
          'updated_at': 1,
        });
        await txn.insert('documents', <String, Object?>{
          'id': 'doc1',
          'title': 'سند',
          'created_at': 1,
          'updated_at': 1,
        });
        for (final id in ['f1', 'f2']) {
          await txn.insert('document_files', <String, Object?>{
            'id': id,
            'document_id': 'doc1',
            'encrypted_file_name': '$id.enc',
            'original_extension': id == 'f1' ? 'jpg' : 'pdf',
            'mime_type': id == 'f1' ? 'image/jpeg' : 'application/pdf',
            'encrypted_size': 100,
            'checksum': 'abc',
            'created_at': 1,
          });
        }
        await account(
          txn,
          'a1',
          'علي',
          phone: '777',
          notes: 'ملاحظة',
          createdAt: 10,
        );
        await account(txn, 'a2', 'خالد', archived: true, createdAt: 20);
        await account(txn, 'a3', 'فارغ', createdAt: 30);

        // a1: SAR debit-side 10000, credit-side 2500, negative adjustment 300.
        await entry(txn, 'e1', 'a1', 'loanGiven', 10000, 'SAR',
            _utc(2024, 12, 13, 14, 30),
            notes: 'يوم موت أبي', attachmentId: 'f1', createdAt: 100);
        await entry(txn, 'e2', 'a1', 'paymentReceived', 2500, 'SAR',
            _utc(2024, 12, 20, 9, 5), createdAt: 200);
        await entry(txn, 'e3', 'a1', 'adjustment', -300, 'SAR',
            _utc(2025, 1, 1), createdAt: 300);
        // a1: a second currency splits into its own book account.
        await entry(txn, 'e4', 'a1', 'loanTaken', 500, 'USD',
            _utc(2025, 2, 1), createdAt: 400);
        // a2: archived, currency unknown to the registry.
        await entry(txn, 'e5', 'a2', 'paymentMade', 1000, 'XYZ',
            _utc(2025, 3, 1), createdAt: 500);
        // Rows the new table cannot hold: zero amount and unknown type.
        await entry(txn, 'e6', 'a2', 'loanGiven', 0, 'XYZ',
            _utc(2025, 3, 2), createdAt: 600);
        await entry(txn, 'e7', 'a2', 'weird', 900, 'XYZ',
            _utc(2025, 3, 3), createdAt: 700);
        await txn.insert('attachment_refs', <String, Object?>{
          'id': 'r1',
          'owner_type': 'ledger_entry',
          'owner_id': 'e2',
          'document_file_id': 'f2',
          'created_at': 1,
        });
      });

      final app = AppDatabase(path: path);
      final db = await app.database;
      expect(await db.getVersion(), AppDatabase.schemaVersion);

      final categories = await db.query('book_categories');
      expect(categories, hasLength(1));
      expect(categories.single['name'], 'الأشخاص والسلف القديمة');
      expect(categories.single['is_active'], 1);
      expect(categories.single['is_archived'], 0);

      final accounts = {
        for (final row in await db.query('book_accounts'))
          row['id']! as String: row,
      };
      expect(accounts.keys, {
        'legacy-a1-SAR',
        'legacy-a1-USD',
        'legacy-a2-XYZ',
        'legacy-a3-YER',
      });
      expect(accounts['legacy-a1-SAR']!['name'], 'علي (SAR)');
      expect(accounts['legacy-a1-USD']!['name'], 'علي (USD)');
      expect(accounts['legacy-a1-SAR']!['notes'], 'الهاتف: 777\nملاحظة');
      expect(accounts['legacy-a1-SAR']!['status'], 'active');
      expect(accounts['legacy-a2-XYZ']!['name'], 'خالد');
      expect(accounts['legacy-a2-XYZ']!['status'], 'archived');
      expect(accounts['legacy-a3-YER']!['name'], 'فارغ');
      // Since v14 an account's currency and opening live in
      // `book_account_balances` (one row per account and currency).
      final balances = {
        for (final row in await db.query('book_account_balances'))
          row['account_id']! as String: row,
      };
      expect(balances['legacy-a3-YER']!['currency_code'], 'YER');
      expect(balances['legacy-a1-SAR']!['currency_code'], 'SAR');
      expect(balances.keys, accounts.keys);
      for (final row in accounts.values) {
        expect(row['category_id'], 'legacy-people-category');
      }
      for (final row in balances.values) {
        expect(row['opening_type'], 'ZERO');
        expect(row['opening_minor'], 0);
      }

      // The unknown currency was registered inactive so the FK holds.
      final xyz = await db.query(
        'currencies',
        where: 'code = ?',
        whereArgs: ['XYZ'],
      );
      expect(xyz.single['is_active'], 0);

      final txs = await db.query(
        'book_transactions',
        orderBy: 'transaction_number ASC',
      );
      expect(txs.map((r) => r['id']), ['e1', 'e2', 'e3', 'e4', 'e5']);
      expect(txs.map((r) => r['transaction_number']), [
        'TX-000001',
        'TX-000002',
        'TX-000003',
        'TX-000004',
        'TX-000005',
      ]);
      final byId = {for (final r in txs) r['id']! as String: r};
      expect(byId['e1']!['type'], 'DEBIT');
      expect(byId['e1']!['amount_minor'], 10000);
      expect(byId['e1']!['transaction_date'], '2024-12-13');
      expect(byId['e1']!['transaction_time'], '14:30');
      expect(byId['e1']!['details'], 'سلفة أعطيتها');
      expect(byId['e1']!['notes'], 'يوم موت أبي');
      expect(byId['e1']!['balance_after'], 10000);
      expect(byId['e2']!['type'], 'CREDIT');
      expect(byId['e2']!['balance_after'], 7500);
      expect(byId['e3']!['type'], 'CREDIT');
      expect(byId['e3']!['amount_minor'], 300);
      expect(byId['e3']!['balance_after'], 7200);
      expect(byId['e4']!['type'], 'CREDIT');
      expect(byId['e4']!['balance_after'], -500);
      expect(byId['e5']!['type'], 'DEBIT');
      expect(byId['e5']!['balance_after'], 1000);
      expect(byId['e3']!['created_at'], 300);

      final counter = await db.query('book_counters');
      expect(counter.single['name'], 'tx_number');
      expect(counter.single['value'], 5);

      // Attachments: both sources become references to the untouched files.
      final attachments = await db.query(
        'book_attachments',
        orderBy: 'transaction_id ASC',
      );
      expect(attachments, hasLength(2));
      expect(attachments[0]['transaction_id'], 'e1');
      expect(attachments[0]['document_file_id'], 'f1');
      expect(attachments[0]['encrypted_file_name'], isNull);
      expect(attachments[0]['kind'], 'image');
      expect(attachments[1]['transaction_id'], 'e2');
      expect(attachments[1]['document_file_id'], 'f2');
      expect(attachments[1]['kind'], 'pdf');

      // Schema v8 then removes the copied-from tables (see migration_v8_test),
      // but the files the book's attachments point at are never touched.
      expect(await db.query('document_files'), hasLength(2));
      await app.close();
    },
  );

  test('orders same-day entries by time then creation', () async {
    await createV6((txn) async {
      await account(txn, 'a1', 'علي');
      await entry(txn, 'late', 'a1', 'loanGiven', 100, 'SAR',
          _utc(2025, 1, 5, 18), createdAt: 1);
      await entry(txn, 'early', 'a1', 'loanGiven', 200, 'SAR',
          _utc(2025, 1, 5, 8), createdAt: 2);
    });
    final app = AppDatabase(path: path);
    final db = await app.database;
    final txs = await db.query(
      'book_transactions',
      orderBy: 'transaction_number ASC',
    );
    expect(txs.map((r) => r['id']), ['early', 'late']);
    expect(txs.map((r) => r['balance_after']), [200, 300]);
    await app.close();
  });

  test('a failing migration rolls back and leaves version 6 intact', () async {
    await createV6((txn) async {
      await account(txn, 'a1', 'علي');
      await entry(txn, 'e1', 'a1', 'loanGiven', 100, 'SAR', _utc(2025, 1, 5));
      // A colliding table makes MigrationV7's CREATE TABLE fail.
      await txn.execute('CREATE TABLE book_categories (id TEXT)');
    });
    final app = AppDatabase(path: path);
    await expectLater(
      app.database,
      throwsA(
        isA<StorageException>().having(
          (e) => e.code,
          'code',
          'database_migration_failed',
        ),
      ),
    );
    expect(app.snapshotFileName, isNotNull);
    await app.close();

    final raw = await openDatabase(path, readOnly: true);
    expect(await raw.getVersion(), 6);
    expect(await raw.query('ledger_entries'), hasLength(1));
    final tables = await raw.rawQuery(
      "SELECT name FROM sqlite_master WHERE name = 'book_accounts'",
    );
    expect(tables, isEmpty);
    await raw.close();
  });

  group('pre-upgrade snapshot', () {
    List<File> snapshots() => sandbox
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.bak'))
        .toList();

    test('is taken before v6 -> v7 and opens as the untouched v6', () async {
      await createV6((txn) async {
        await account(txn, 'a1', 'علي');
        await entry(txn, 'e1', 'a1', 'loanGiven', 100, 'SAR', _utc(2025, 1, 5));
      });
      final app = AppDatabase(path: path);
      await app.database;
      final files = snapshots();
      expect(files, hasLength(1));
      expect(app.snapshotFileName, files.single.uri.pathSegments.last);
      expect(
        app.snapshotFileName,
        contains('.pre-v${AppDatabase.schemaVersion}-'),
      );
      await app.close();

      final raw = await openDatabase(files.single.path, readOnly: true);
      expect(await raw.getVersion(), 6);
      expect(await raw.query('ledger_entries'), hasLength(1));
      expect(
        await raw.rawQuery(
          "SELECT name FROM sqlite_master WHERE name = 'book_accounts'",
        ),
        isEmpty,
      );
      await raw.close();
    });

    test(
      'is not taken on a fresh install or an already current database',
      () async {
        final fresh = AppDatabase(path: path);
        await fresh.database;
        await fresh.close();
        expect(snapshots(), isEmpty);
        expect(fresh.snapshotFileName, isNull);

        final again = AppDatabase(path: path);
        await again.database;
        await again.close();
        expect(snapshots(), isEmpty);
      },
    );

    test('keeps only the two most recent snapshots', () async {
      await createV6((txn) async {});
      final old = DateTime.now().subtract(const Duration(days: 3));
      for (var index = 0; index < 3; index++) {
        final stale = File('$path.pre-v7-$index.bak');
        await stale.writeAsBytes(<int>[1, 2, 3]);
        await stale.setLastModified(old.add(Duration(hours: index)));
      }
      final app = AppDatabase(path: path);
      await app.database;
      await app.close();
      final names = snapshots().map((f) => f.uri.pathSegments.last).toSet();
      expect(names, hasLength(2));
      expect(names, contains(app.snapshotFileName));
      expect(names, contains('database.sqlite.pre-v7-2.bak'));
    });

    test('concurrent first opens share one open and one snapshot', () async {
      await createV6((txn) async {});
      final app = AppDatabase(path: path);
      final results = await Future.wait([app.database, app.database]);
      expect(identical(results[0], results[1]), isTrue);
      expect(snapshots(), hasLength(1));
      await app.close();
    });
  });
}
