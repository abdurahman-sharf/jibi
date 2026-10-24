import 'package:sqflite/sqflite.dart';

import '../errors/app_exception.dart';
import 'app_database.dart';

/// Schema v14: one account can hold several currencies at once.
///
/// Until now an account had exactly one currency (`book_accounts.currency_code`)
/// that every transaction of it inherited, and its opening balance lived in two
/// fixed columns. From here on an account is the person or entity, and the
/// currency belongs to each transaction:
///
/// - `book_transactions` gains its own `currency_code` (NOT NULL, references
///   `currencies`), backfilled from the account's old currency;
/// - the opening balance moves to `book_account_balances`, one row per
///   (account, currency) — nothing is fixed to a list of currencies;
/// - `book_accounts` loses `currency_code`, `opening_minor` and `opening_type`.
///
/// The running balance (`book_transactions.balance_after`) keeps its meaning:
/// it is now per (account, currency). Every pre-v14 account had one currency,
/// so every stored value is already correct and nothing is recomputed here.
///
/// **Why four tables are rebuilt.** SQLite 3.9 (Android 7, `minSdk 24`) has no
/// `DROP COLUMN`, and `ADD COLUMN` cannot add a `NOT NULL` column without a
/// default. `book_accounts` is a *parent* (`book_transactions.account_id`
/// references it with `ON DELETE RESTRICT`), and with foreign keys on (set in
/// `onConfigure`, unchangeable inside this transaction) dropping a parent whose
/// children still have rows is vetoed, while `ALTER TABLE ... RENAME TO` only
/// rewrites other tables' foreign keys from SQLite 3.25. So, like
/// [MigrationV12], every dependent child is stashed and dropped first
/// (`wallet_transactions` and `book_attachments`, which point at
/// `book_transactions`), then `book_transactions`, then `book_accounts`; the
/// four are recreated under their final names and refilled, parents first.
///
/// A failure aborts app startup on every launch (and Android cannot downgrade),
/// so nothing here throws on odd data. The safety net is the single transaction
/// this runs in, a row-count check that rolls everything back if a table did
/// not come back whole, and the `.pre-v14-*.bak` file snapshot the app takes
/// before any upgrade.
///
/// The old `payment_method` label column is kept (unread, unwritten) exactly as
/// v11 left it.
final class MigrationV14 implements DatabaseMigration {
  const MigrationV14();

  @override
  int get version => 14;

  @override
  Future<void> apply(Transaction txn) async {
    final before = await _counts(txn);
    await _stash(txn);
    await _dropOld(txn);
    await _createAccounts(txn);
    await _createAccountBalances(txn);
    await _createTransactions(txn);
    await _createAttachments(txn);
    await _createWalletTransactions(txn);
    await _dropScaffolding(txn);
    final after = await _counts(txn);
    if (before.accounts != after.accounts ||
        before.transactions != after.transactions ||
        before.attachments != after.attachments ||
        before.walletTransactions != after.walletTransactions) {
      // Rolls the whole upgrade back; the database stays at v13.
      throw const StorageException(
        code: 'database_migration_failed',
        userMessage:
            'تعذر تحديث قاعدة البيانات إلى الإصدار الجديد. بياناتك سليمة '
            'ولم تتغير. حدّث التطبيق إلى أحدث نسخة أو راجع المطوّر.',
      );
    }
  }

  Future<({int accounts, int transactions, int attachments, int walletTransactions})>
  _counts(Transaction txn) async {
    Future<int> count(String table) async =>
        Sqflite.firstIntValue(await txn.rawQuery('SELECT COUNT(*) FROM $table')) ??
        0;
    return (
      accounts: await count('book_accounts'),
      transactions: await count('book_transactions'),
      attachments: await count('book_attachments'),
      walletTransactions: await count('wallet_transactions'),
    );
  }

  /// Copies the rows into plain, constraint-free tables so the real ones can
  /// be dropped and their data reinserted under the new shape.
  Future<void> _stash(Transaction txn) async {
    for (final (stash, source) in const [
      ('_v14_accounts', 'book_accounts'),
      ('_v14_tx', 'book_transactions'),
      ('_v14_attachments', 'book_attachments'),
      ('_v14_wtx', 'wallet_transactions'),
    ]) {
      await txn.execute('CREATE TABLE $stash AS SELECT * FROM $source');
    }
  }

  /// Children first: nothing may still reference a table when it goes.
  Future<void> _dropOld(Transaction txn) async {
    for (final table in const [
      'wallet_transactions',
      'book_attachments',
      'book_transactions',
      'book_accounts',
    ]) {
      await txn.execute('DROP TABLE $table');
    }
  }

  Future<void> _createAccounts(Transaction txn) async {
    await txn.execute('''
      CREATE TABLE book_accounts (
        id TEXT NOT NULL PRIMARY KEY,
        category_id TEXT NOT NULL
          REFERENCES book_categories(id) ON DELETE RESTRICT,
        name TEXT NOT NULL,
        notes TEXT,
        status TEXT NOT NULL DEFAULT 'active'
          CHECK (status IN ('active', 'suspended', 'archived')),
        sort_order INTEGER NOT NULL DEFAULT 0,
        legacy_account_id TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        phone TEXT
      )
    ''');
    await txn.execute('''
      INSERT INTO book_accounts
        (id, category_id, name, notes, status, sort_order, legacy_account_id,
         created_at, updated_at, phone)
      SELECT id, category_id, name, notes, status, sort_order,
             legacy_account_id, created_at, updated_at, phone
      FROM _v14_accounts
    ''');
    await txn.execute(
      'CREATE INDEX idx_book_accounts_category ON book_accounts(category_id)',
    );
  }

  /// One row per (account, currency): the opening balance in that currency.
  /// Every pre-v14 account gets exactly one, carrying its old currency and
  /// opening — even at zero, since the row is what declares the account uses
  /// that currency. The amount and its side are normalised so that "zero" and
  /// an amount of 0 always go together (an odd row could never be read before
  /// either).
  Future<void> _createAccountBalances(Transaction txn) async {
    await txn.execute('''
      CREATE TABLE book_account_balances (
        account_id TEXT NOT NULL
          REFERENCES book_accounts(id) ON DELETE CASCADE,
        currency_code TEXT NOT NULL
          REFERENCES currencies(code) ON DELETE RESTRICT,
        opening_minor INTEGER NOT NULL DEFAULT 0 CHECK (opening_minor >= 0),
        opening_type TEXT NOT NULL DEFAULT 'ZERO'
          CHECK (opening_type IN ('DEBIT', 'CREDIT', 'ZERO')),
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (account_id, currency_code),
        CHECK ((opening_type = 'ZERO') = (opening_minor = 0))
      )
    ''');
    await txn.execute('''
      INSERT INTO book_account_balances
        (account_id, currency_code, opening_minor, opening_type, created_at,
         updated_at)
      SELECT id, currency_code,
             CASE WHEN opening_type NOT IN ('DEBIT', 'CREDIT')
                    OR opening_minor <= 0 THEN 0 ELSE opening_minor END,
             CASE WHEN opening_type NOT IN ('DEBIT', 'CREDIT')
                    OR opening_minor <= 0 THEN 'ZERO' ELSE opening_type END,
             created_at, updated_at
      FROM _v14_accounts
    ''');
    await txn.execute(
      'CREATE INDEX idx_book_account_balances_currency '
      'ON book_account_balances(currency_code)',
    );
  }

  Future<void> _createTransactions(Transaction txn) async {
    await txn.execute('''
      CREATE TABLE book_transactions (
        id TEXT NOT NULL PRIMARY KEY,
        transaction_number TEXT NOT NULL UNIQUE,
        account_id TEXT NOT NULL
          REFERENCES book_accounts(id) ON DELETE RESTRICT,
        currency_code TEXT NOT NULL
          REFERENCES currencies(code) ON DELETE RESTRICT,
        type TEXT NOT NULL CHECK (type IN ('DEBIT', 'CREDIT')),
        amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
        transaction_date TEXT NOT NULL,
        transaction_time TEXT NOT NULL DEFAULT '00:00',
        details TEXT,
        notes TEXT,
        balance_after INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        deleted_at INTEGER,
        wallet_id TEXT REFERENCES wallets(id) ON DELETE RESTRICT,
        wallet_effect TEXT,
        payment_method TEXT
      )
    ''');
    await txn.execute('''
      INSERT INTO book_transactions
        (id, transaction_number, account_id, currency_code, type, amount_minor,
         transaction_date, transaction_time, details, notes, balance_after,
         created_at, updated_at, deleted_at, wallet_id, wallet_effect,
         payment_method)
      SELECT t.id, t.transaction_number, t.account_id, a.currency_code, t.type,
             t.amount_minor, t.transaction_date, t.transaction_time, t.details,
             t.notes, t.balance_after, t.created_at, t.updated_at, t.deleted_at,
             t.wallet_id, t.wallet_effect, t.payment_method
      FROM _v14_tx t JOIN _v14_accounts a ON a.id = t.account_id
    ''');
    await txn.execute(
      'CREATE INDEX idx_book_tx_account_date ON book_transactions('
      'account_id, transaction_date, transaction_time)',
    );
    await txn.execute(
      'CREATE INDEX idx_book_tx_account_currency_date ON book_transactions('
      'account_id, currency_code, transaction_date, transaction_time, '
      'created_at, id)',
    );
    await txn.execute(
      'CREATE INDEX idx_book_tx_account_type '
      'ON book_transactions(account_id, type)',
    );
    await txn.execute(
      'CREATE INDEX idx_book_tx_date ON book_transactions(transaction_date)',
    );
    await txn.execute(
      'CREATE INDEX idx_book_tx_currency ON book_transactions(currency_code)',
    );
    await txn.execute(
      'CREATE INDEX idx_book_tx_wallet ON book_transactions(wallet_id)',
    );
  }

  Future<void> _createAttachments(Transaction txn) async {
    await txn.execute('''
      CREATE TABLE book_attachments (
        id TEXT NOT NULL PRIMARY KEY,
        transaction_id TEXT NOT NULL
          REFERENCES book_transactions(id) ON DELETE CASCADE,
        kind TEXT NOT NULL DEFAULT 'document',
        file_name TEXT NOT NULL,
        mime_type TEXT NOT NULL,
        encrypted_file_name TEXT UNIQUE,
        original_extension TEXT,
        file_size INTEGER NOT NULL DEFAULT 0 CHECK (file_size >= 0),
        checksum TEXT,
        document_file_id TEXT
          REFERENCES document_files(id) ON DELETE RESTRICT,
        created_at INTEGER NOT NULL,
        CHECK ((encrypted_file_name IS NULL) <> (document_file_id IS NULL))
      )
    ''');
    await txn.execute('''
      INSERT INTO book_attachments
        (id, transaction_id, kind, file_name, mime_type, encrypted_file_name,
         original_extension, file_size, checksum, document_file_id, created_at)
      SELECT id, transaction_id, kind, file_name, mime_type,
             encrypted_file_name, original_extension, file_size, checksum,
             document_file_id, created_at
      FROM _v14_attachments
    ''');
    await txn.execute(
      'CREATE INDEX idx_book_attachments_tx ON book_attachments(transaction_id)',
    );
  }

  /// Recreated exactly as [MigrationV12] left it; only its parent changed.
  Future<void> _createWalletTransactions(Transaction txn) async {
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
      SELECT id, transaction_number, wallet_id, currency_code, type, direction,
             amount_minor, balance_after, leg_group_id,
             linked_book_transaction_id, transaction_date, transaction_time,
             notes, created_at, updated_at, deleted_at
      FROM _v14_wtx
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

  Future<void> _dropScaffolding(Transaction txn) async {
    for (final table in const [
      '_v14_accounts',
      '_v14_tx',
      '_v14_attachments',
      '_v14_wtx',
    ]) {
      await txn.execute('DROP TABLE $table');
    }
  }
}
