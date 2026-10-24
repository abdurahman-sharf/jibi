import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'app_database.dart';

/// Schema v11: the wallets/boxes feature.
///
/// Adds `wallets` (cash boxes and bank wallets) and `wallet_transactions`
/// (deposits, withdrawals, transfers between two wallets, and — from a later
/// phase — movements linked to a book transaction). `book_transactions` gets
/// three columns (`wallet_id`, `wallet_effect`, `payment_method`) so that
/// later linkage needs no further migration; they are unused until then.
///
/// Seeds exactly one wallet, the main cash box («الصندوق الرئيسي»), so the
/// app always has somewhere to represent cash in hand. A partial unique index
/// keeps at most one wallet flagged `is_main` at the database level; deleting
/// the main wallet is allowed like any other (no special protection), so the
/// app may end up with none flagged main until the user promotes another one.
final class MigrationV11 implements DatabaseMigration {
  const MigrationV11();

  static const mainWalletId = 'main-wallet';
  static const mainWalletName = 'الصندوق الرئيسي';

  @override
  int get version => 11;

  @override
  Future<void> apply(Transaction transaction) async {
    await _createSchema(transaction);
    await _seedMainWallet(transaction);
  }

  Future<void> _createSchema(Transaction txn) async {
    await txn.execute('''
      CREATE TABLE wallets (
        id TEXT NOT NULL PRIMARY KEY,
        name TEXT NOT NULL,
        wallet_type TEXT NOT NULL DEFAULT 'bank'
          CHECK (wallet_type IN ('cash', 'bank')),
        is_main INTEGER NOT NULL DEFAULT 0 CHECK (is_main IN (0, 1)),
        account_number TEXT,
        currency_code TEXT NOT NULL REFERENCES currencies(code)
          ON DELETE RESTRICT,
        opening_minor INTEGER NOT NULL DEFAULT 0 CHECK (opening_minor >= 0),
        image BLOB,
        notes TEXT,
        status TEXT NOT NULL DEFAULT 'active'
          CHECK (status IN ('active', 'archived')),
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await txn.execute(
      'CREATE UNIQUE INDEX idx_wallets_single_main ON wallets(is_main) '
      'WHERE is_main = 1',
    );
    await txn.execute('''
      CREATE TABLE wallet_transactions (
        id TEXT NOT NULL PRIMARY KEY,
        transaction_number TEXT NOT NULL UNIQUE,
        wallet_id TEXT NOT NULL REFERENCES wallets(id) ON DELETE RESTRICT,
        type TEXT NOT NULL
          CHECK (type IN ('deposit', 'withdrawal', 'transfer', 'linked')),
        direction TEXT NOT NULL CHECK (direction IN ('IN', 'OUT')),
        amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
        balance_after INTEGER NOT NULL DEFAULT 0,
        transfer_group_id TEXT,
        linked_book_transaction_id TEXT
          REFERENCES book_transactions(id) ON DELETE RESTRICT,
        transaction_date TEXT NOT NULL,
        transaction_time TEXT NOT NULL DEFAULT '00:00',
        notes TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        deleted_at INTEGER,
        CHECK (type = 'transfer' OR transfer_group_id IS NULL),
        CHECK (type = 'linked' OR linked_book_transaction_id IS NULL),
        CHECK (type != 'linked' OR linked_book_transaction_id IS NOT NULL)
      )
    ''');
    await txn.execute(
      'CREATE INDEX idx_wtx_wallet_date ON wallet_transactions('
      'wallet_id, transaction_date, transaction_time)',
    );
    await txn.execute(
      'CREATE INDEX idx_wtx_linked ON wallet_transactions('
      'linked_book_transaction_id)',
    );
    await txn.execute(
      'CREATE INDEX idx_wtx_transfer_group ON wallet_transactions('
      'transfer_group_id)',
    );
    await txn.execute(
      'ALTER TABLE book_transactions ADD COLUMN wallet_id TEXT '
      'REFERENCES wallets(id) ON DELETE RESTRICT',
    );
    // 'INCREASE' | 'DECREASE'; validated in Dart only, wired up in a later
    // phase together with the transaction form.
    await txn.execute(
      'ALTER TABLE book_transactions ADD COLUMN wallet_effect TEXT',
    );
    // A short fixed list (cash/bank transfer/card/...); validated in Dart
    // only, wired up in the same later phase.
    await txn.execute(
      'ALTER TABLE book_transactions ADD COLUMN payment_method TEXT',
    );
    await txn.execute(
      'CREATE INDEX idx_book_tx_wallet ON book_transactions(wallet_id)',
    );
  }

  Future<void> _seedMainWallet(Transaction txn) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await txn.insert('wallets', <String, Object?>{
      'id': mainWalletId,
      'name': mainWalletName,
      'wallet_type': 'cash',
      'is_main': 1,
      'account_number': null,
      'currency_code': await _fallbackCurrency(txn, now: now),
      'opening_minor': 0,
      'status': 'active',
      'sort_order': 0,
      'created_at': now,
      'updated_at': now,
    });
  }

  /// Currency for the seeded main wallet: the saved default when it still
  /// exists, else the first active currency, else a seeded SAR. Mirrors
  /// `MigrationV7`'s own fallback, reimplemented here because migrations must
  /// stay frozen and self-contained.
  Future<String> _fallbackCurrency(Transaction txn, {required int now}) async {
    String? saved;
    try {
      final rows = await txn.query(
        'app_settings',
        columns: <String>['value'],
        where: 'key = ?',
        whereArgs: <Object?>['settings_v1'],
      );
      if (rows.isNotEmpty) {
        final decoded = jsonDecode(rows.single['value']! as String);
        if (decoded is Map && decoded['defaultCurrencyCode'] is String) {
          saved = (decoded['defaultCurrencyCode']! as String).toUpperCase();
        }
      }
    } on Object {
      saved = null;
    }
    if (saved != null) {
      final exists = await txn.query(
        'currencies',
        columns: <String>['code'],
        where: 'code = ?',
        whereArgs: <Object?>[saved],
      );
      if (exists.isNotEmpty) {
        return saved;
      }
    }
    final first = await txn.query(
      'currencies',
      columns: <String>['code'],
      where: 'is_active = 1',
      orderBy: 'sort_order ASC, code ASC',
      limit: 1,
    );
    if (first.isNotEmpty) {
      return first.single['code']! as String;
    }
    await txn.rawInsert(
      'INSERT OR IGNORE INTO currencies '
      '(code, name, symbol, fraction_digits, sort_order, is_active, '
      'created_at, updated_at) '
      'VALUES (?, ?, ?, ?, '
      '(SELECT COALESCE(MAX(sort_order), -1) + 1 FROM currencies), 1, ?, ?)',
      <Object?>['SAR', 'ريال سعودي', 'ر.س', 2, now, now],
    );
    return 'SAR';
  }
}
