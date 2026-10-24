import 'package:sqflite/sqflite.dart';

import 'app_database.dart';

/// Schema v12: a wallet can hold several currencies at once.
///
/// Moves currency off `wallets` (one row, one place) and onto a new
/// `wallet_balances` row per (wallet, currency) — the running balance is still
/// derived from movements, never stored here except as the opening amount.
/// `wallet_transactions` gains its own `currency_code` (a movement's currency
/// no longer follows its wallet, since the wallet can hold several) and a new
/// `exchange` type (converting between two currencies inside one wallet);
/// `transfer_group_id` is renamed `leg_group_id` since it now groups the legs
/// of either a transfer or an exchange.
///
/// `wallets` is dropped and rebuilt under its own name rather than renamed,
/// unlike [MigrationV6] or [MigrationV8]'s child-table rebuilds. `wallets` is
/// a *parent*: `wallet_transactions.wallet_id` and `book_transactions.wallet_id`
/// both reference it with `ON DELETE RESTRICT`, and with foreign keys on (set
/// in `onConfigure`, unchangeable inside this transaction) `DROP TABLE wallets`
/// performs an implicit delete that a RESTRICT child with rows would veto.
/// `ALTER TABLE ... RENAME TO` is not the escape hatch either: it only rewrites
/// other tables' foreign-key references from SQLite 3.25, and this app's
/// `minSdk 24` (Android 7) ships SQLite 3.9. So every child is stashed and
/// dropped first (`wallet_transactions`, and `book_transactions.wallet_id` is
/// cleared and restored afterward), only then is `wallets` dropped and
/// recreated under its final name, and only then are the children rebuilt.
///
/// A failure aborts app startup on every launch (and Android cannot
/// downgrade), so nothing here throws on odd data — the safety net is the
/// single transaction this runs in, plus the `.pre-v12-*.bak` file snapshot
/// taken before any upgrade.
final class MigrationV12 implements DatabaseMigration {
  const MigrationV12();

  @override
  int get version => 12;

  @override
  Future<void> apply(Transaction txn) async {
    await _detachBookLinks(txn);
    await _stashWalletTransactions(txn);
    await _rebuildWallets(txn);
    await _createWalletBalances(txn);
    await _rebuildWalletTransactions(txn);
    await _reattachBookLinks(txn);
    await _dropScaffolding(txn);
  }

  /// `book_transactions.wallet_id` also references `wallets`; cleared for the
  /// duration so dropping `wallets` implies no RESTRICT-violating delete.
  Future<void> _detachBookLinks(Transaction txn) async {
    await txn.execute('''
      CREATE TABLE _v12_book_wallet (
        tx_id TEXT NOT NULL PRIMARY KEY,
        wallet_id TEXT NOT NULL
      )
    ''');
    await txn.execute(
      'INSERT INTO _v12_book_wallet (tx_id, wallet_id) '
      'SELECT id, wallet_id FROM book_transactions WHERE wallet_id IS NOT NULL',
    );
    await txn.execute(
      'UPDATE book_transactions SET wallet_id = NULL WHERE wallet_id IS NOT NULL',
    );
  }

  /// A child table can always be dropped; stashed first (with no foreign
  /// keys of its own) so its rows survive to be reinserted with their new
  /// `currency_code` once the parent has its final shape.
  Future<void> _stashWalletTransactions(Transaction txn) async {
    await txn.execute('''
      CREATE TABLE _v12_wtx (
        id TEXT, transaction_number TEXT, wallet_id TEXT, type TEXT,
        direction TEXT, amount_minor INTEGER, balance_after INTEGER,
        transfer_group_id TEXT, linked_book_transaction_id TEXT,
        transaction_date TEXT, transaction_time TEXT, notes TEXT,
        created_at INTEGER, updated_at INTEGER, deleted_at INTEGER
      )
    ''');
    await txn.execute('''
      INSERT INTO _v12_wtx
      SELECT id, transaction_number, wallet_id, type, direction, amount_minor,
             balance_after, transfer_group_id, linked_book_transaction_id,
             transaction_date, transaction_time, notes, created_at,
             updated_at, deleted_at
      FROM wallet_transactions
    ''');
    await txn.execute('DROP TABLE wallet_transactions');
  }

  /// Stashes the old wallets (their `currency_code`/`opening_minor` seed the
  /// new balance rows), then drops and recreates `wallets` under its final
  /// name — safe now that `wallet_transactions` is gone and no
  /// `book_transactions.wallet_id` still points here.
  Future<void> _rebuildWallets(Transaction txn) async {
    await txn.execute('''
      CREATE TABLE _v12_wallets (
        id TEXT, name TEXT, is_main INTEGER, account_number TEXT,
        currency_code TEXT, opening_minor INTEGER, image BLOB, notes TEXT,
        status TEXT, sort_order INTEGER, created_at INTEGER, updated_at INTEGER
      )
    ''');
    await txn.execute('''
      INSERT INTO _v12_wallets
      SELECT id, name, is_main, account_number, currency_code, opening_minor,
             image, notes, status, sort_order, created_at, updated_at
      FROM wallets
    ''');
    await txn.execute('DROP TABLE wallets');
    await txn.execute('''
      CREATE TABLE wallets (
        id TEXT NOT NULL PRIMARY KEY,
        name TEXT NOT NULL,
        is_main INTEGER NOT NULL DEFAULT 0 CHECK (is_main IN (0, 1)),
        account_number TEXT,
        image BLOB,
        notes TEXT,
        status TEXT NOT NULL DEFAULT 'active'
          CHECK (status IN ('active', 'archived')),
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await txn.execute('''
      INSERT INTO wallets
        (id, name, is_main, account_number, image, notes, status, sort_order,
         created_at, updated_at)
      SELECT id, name, is_main, account_number, image, notes, status,
             sort_order, created_at, updated_at
      FROM _v12_wallets
    ''');
    await txn.execute(
      'CREATE UNIQUE INDEX idx_wallets_single_main ON wallets(is_main) '
      'WHERE is_main = 1',
    );
  }

  /// One row per (wallet, currency). Every pre-v12 wallet gets exactly one,
  /// carrying its old currency and opening balance — even when both were
  /// zero, since the row alone is what declares the wallet holds that
  /// currency at all.
  Future<void> _createWalletBalances(Transaction txn) async {
    await txn.execute('''
      CREATE TABLE wallet_balances (
        wallet_id TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
        currency_code TEXT NOT NULL REFERENCES currencies(code)
          ON DELETE RESTRICT,
        opening_minor INTEGER NOT NULL DEFAULT 0 CHECK (opening_minor >= 0),
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (wallet_id, currency_code)
      )
    ''');
    await txn.execute('''
      INSERT INTO wallet_balances
        (wallet_id, currency_code, opening_minor, sort_order, created_at,
         updated_at)
      SELECT id, currency_code, opening_minor, 0, created_at, updated_at
      FROM _v12_wallets
    ''');
    await txn.execute(
      'CREATE INDEX idx_wallet_balances_currency '
      'ON wallet_balances(currency_code)',
    );
  }

  /// Recreates `wallet_transactions` with its own `currency_code` (backfilled
  /// from the movement's wallet — every pre-v12 wallet had exactly one), the
  /// new `exchange` type, and `leg_group_id` in place of `transfer_group_id`.
  Future<void> _rebuildWalletTransactions(Transaction txn) async {
    await txn.execute('''
      CREATE TABLE wallet_transactions (
        id TEXT NOT NULL PRIMARY KEY,
        transaction_number TEXT NOT NULL UNIQUE,
        wallet_id TEXT NOT NULL REFERENCES wallets(id) ON DELETE RESTRICT,
        currency_code TEXT NOT NULL REFERENCES currencies(code)
          ON DELETE RESTRICT,
        type TEXT NOT NULL CHECK (type IN
          ('deposit', 'withdrawal', 'transfer', 'exchange', 'linked')),
        direction TEXT NOT NULL CHECK (direction IN ('IN', 'OUT')),
        amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
        balance_after INTEGER NOT NULL DEFAULT 0,
        leg_group_id TEXT,
        linked_book_transaction_id TEXT
          REFERENCES book_transactions(id) ON DELETE RESTRICT,
        transaction_date TEXT NOT NULL,
        transaction_time TEXT NOT NULL DEFAULT '00:00',
        notes TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        deleted_at INTEGER,
        CHECK (type IN ('transfer', 'exchange') OR leg_group_id IS NULL),
        CHECK (type NOT IN ('transfer', 'exchange') OR leg_group_id IS NOT NULL),
        CHECK (type = 'linked' OR linked_book_transaction_id IS NULL),
        CHECK (type != 'linked' OR linked_book_transaction_id IS NOT NULL)
      )
    ''');
    await txn.execute('''
      INSERT INTO wallet_transactions
        (id, transaction_number, wallet_id, currency_code, type, direction,
         amount_minor, balance_after, leg_group_id, linked_book_transaction_id,
         transaction_date, transaction_time, notes, created_at, updated_at,
         deleted_at)
      SELECT t.id, t.transaction_number, t.wallet_id, w.currency_code, t.type,
             t.direction, t.amount_minor, t.balance_after, t.transfer_group_id,
             t.linked_book_transaction_id, t.transaction_date,
             t.transaction_time, t.notes, t.created_at, t.updated_at,
             t.deleted_at
      FROM _v12_wtx t JOIN _v12_wallets w ON w.id = t.wallet_id
    ''');
    await txn.execute(
      'CREATE INDEX idx_wtx_wallet_currency_date ON wallet_transactions('
      'wallet_id, currency_code, transaction_date, transaction_time, '
      'created_at, id)',
    );
    await txn.execute(
      'CREATE INDEX idx_wtx_linked ON wallet_transactions('
      'linked_book_transaction_id)',
    );
    await txn.execute(
      'CREATE INDEX idx_wtx_leg_group ON wallet_transactions(leg_group_id)',
    );
  }

  Future<void> _reattachBookLinks(Transaction txn) async {
    await txn.execute(
      'UPDATE book_transactions SET wallet_id = '
      '(SELECT wallet_id FROM _v12_book_wallet WHERE tx_id = book_transactions.id) '
      'WHERE id IN (SELECT tx_id FROM _v12_book_wallet)',
    );
  }

  Future<void> _dropScaffolding(Transaction txn) async {
    for (final table in const ['_v12_book_wallet', '_v12_wtx', '_v12_wallets']) {
      await txn.execute('DROP TABLE $table');
    }
  }
}
