import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/core/database/app_database.dart';
import 'package:jibi/core/models/currency_palette.dart';

/// Schema v13 ships three currencies (YER, SAR, USD) without decimal places and
/// gives every currency an optional color. These tests start from a real v12
/// file and check that nothing already holding money is rescaled or removed.
void main() {
  late Directory sandbox;
  late String path;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('jibi_migration_v13_');
    path = '${sandbox.path}${Platform.pathSeparator}database.sqlite';
  });

  tearDown(() async {
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
  });

  const v12Migrations = <DatabaseMigration>[
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
  ];

  /// Builds a v12 database (foreign keys on, like the app): the seeded
  /// currencies, the main wallet, and a saved default currency of SAR — what
  /// onboarding persists — then lets [seed] add more.
  Future<void> createV12(
    Future<void> Function(Transaction txn) seed,
  ) async {
    final legacy = await openDatabase(
      path,
      version: 12,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, version) => db.transaction((txn) async {
        for (final migration in v12Migrations) {
          await migration.apply(txn);
        }
        await txn.insert('app_settings', <String, Object?>{
          'key': 'settings_v1',
          'value': jsonEncode(<String, Object?>{
            'defaultCurrencyCode': 'SAR',
            'localeCode': 'ar',
          }),
          'updated_at': 1,
        });
        await seed(txn);
      }),
    );
    await legacy.close();
  }

  Future<List<Map<String, Object?>>> currencies(Database db) => db.query(
    'currencies',
    orderBy: 'sort_order ASC, code ASC',
  );

  Future<Map<String, Object?>> settings(Database db) async {
    final rows = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['settings_v1'],
    );
    return jsonDecode(rows.single['value']! as String) as Map<String, Object?>;
  }

  test('MigrationV13 is version 13', () {
    expect(const MigrationV13().version, 13);
    expect(AppDatabase.schemaVersion, greaterThanOrEqualTo(13));
  });

  test('an empty device gets YER, SAR, USD without decimals and YER as the '
      'base', () async {
    await createV12((_) async {});
    final app = AppDatabase(path: path);
    final db = await app.database;
    expect(await db.getVersion(), AppDatabase.schemaVersion);

    final rows = await currencies(db);
    expect(rows.map((row) => row['code']), ['YER', 'SAR', 'USD']);
    expect(rows.map((row) => row['fraction_digits']), [0, 0, 0]);
    expect(rows.map((row) => row['sort_order']), [0, 1, 2]);
    expect(rows.map((row) => row['is_active']), [1, 1, 1]);
    expect(rows.map((row) => row['name']), [
      'الريال اليمني',
      'الريال السعودي',
      'الدولار الأمريكي',
    ]);
    expect(rows.map((row) => row['color']), [
      yerCurrencyColor,
      sarCurrencyColor,
      usdCurrencyColor,
    ]);

    final saved = await settings(db);
    expect(saved['defaultCurrencyCode'], 'YER');
    expect(saved['localeCode'], 'ar', reason: 'other settings are kept');

    // The main wallet's empty SAR row now holds the base currency.
    final balances = await db.query('wallet_balances');
    expect(balances.map((row) => row['currency_code']), ['YER']);
    await app.close();
  });

  test('a device holding money keeps its decimals, its base currency and '
      'every used currency', () async {
    await createV12((txn) async {
      await txn.update(
        'wallet_balances',
        <String, Object?>{'opening_minor': 5000},
        where: "currency_code = 'SAR'",
      );
      // A seeded currency a wallet already lists stays; an unused one goes.
      await txn.insert('wallet_balances', <String, Object?>{
        'wallet_id': 'main-wallet',
        'currency_code': 'EUR',
        'opening_minor': 0,
        'sort_order': 1,
        'created_at': 1,
        'updated_at': 1,
      });
      // A currency the owner added is never touched.
      await txn.insert('currencies', <String, Object?>{
        'code': 'JPY',
        'name': 'ين ياباني',
        'symbol': '¥',
        'fraction_digits': 0,
        'sort_order': 50,
        'is_active': 1,
        'created_at': 1,
        'updated_at': 1,
      });
    });
    final app = AppDatabase(path: path);
    final db = await app.database;

    final rows = await currencies(db);
    expect(rows.map((row) => row['code']), ['YER', 'SAR', 'USD', 'EUR', 'JPY']);
    final byCode = {for (final row in rows) row['code']! as String: row};
    expect(byCode['SAR']!['fraction_digits'], 2, reason: 'SAR holds 50.00');
    expect(byCode['USD']!['fraction_digits'], 0);
    expect(byCode['YER']!['fraction_digits'], 0);
    expect(byCode['EUR']!['fraction_digits'], 2, reason: 'used: untouched');
    expect(byCode['KWD'], isNull, reason: 'unused seeded currency is dropped');
    expect(rows.map((row) => row['sort_order']), [0, 1, 2, 3, 4]);

    expect((await settings(db))['defaultCurrencyCode'], 'SAR');
    final balances = await db.query('wallet_balances', orderBy: 'currency_code');
    expect(balances.map((row) => '${row['currency_code']}:${row['opening_minor']}'), [
      'EUR:0',
      'SAR:5000',
    ]);
    await app.close();
  });

  test('archived defaults come back and an edited name is kept', () async {
    await createV12((txn) async {
      await txn.update(
        'currencies',
        <String, Object?>{'is_active': 0, 'name': 'ريالي'},
        where: "code = 'SAR'",
      );
    });
    final app = AppDatabase(path: path);
    final db = await app.database;

    final sar = (await db.query('currencies', where: "code = 'SAR'")).single;
    expect(sar['is_active'], 1);
    expect(sar['name'], 'ريالي');
    final yer = (await db.query('currencies', where: "code = 'YER'")).single;
    expect(yer['name'], 'الريال اليمني');
    await app.close();
  });

  test('only the tables MigrationV13 checks reference currencies', () async {
    // v13 deletes an unused seeded currency; a table it does not know about
    // that references currencies would make that delete fail (or, worse, leave
    // a dangling reference). If this list changes, update the migration's
    // reference check and `isCurrencyUsed` together.
    await createV12((_) async {});
    final app = AppDatabase(path: path);
    final db = await app.database;
    final referencing = {
      for (final row in await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND sql LIKE '%REFERENCES currencies%'",
      ))
        row['name']! as String,
    };
    // Since v14 an account's currencies live in `book_account_balances` and
    // on each `book_transactions` row; `book_accounts` no longer has one.
    expect(referencing, {
      'book_account_balances',
      'book_transactions',
      'wallet_balances',
      'wallet_transactions',
    });
    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    await app.close();
  });

  test('a snapshot of the v12 file is taken and holds the old currencies',
      () async {
    await createV12((_) async {});
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
    expect(await raw.getVersion(), 12);
    expect((await raw.query('currencies')).length, 10);
    final columns = (await raw.rawQuery('PRAGMA table_info(currencies)'))
        .map((row) => row['name'])
        .toSet();
    expect(columns, isNot(contains('color')));
    await raw.close();
  });
}
