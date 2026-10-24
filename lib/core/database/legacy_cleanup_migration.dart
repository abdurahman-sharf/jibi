import 'package:sqflite/sqflite.dart';

import 'app_database.dart';

/// Schema v8: removes the tables of the two systems the book replaced.
///
/// - the old accounts feature: `personal_accounts`, `ledger_entries`;
/// - the unified-ledger (wallets) feature: `wallets`, `persons`,
///   `wallet_transactions`, `advances`, `debts`, `advance_payments`,
///   `debt_payments`.
///
/// The old accounts were copied into the book by [MigrationV7] (and every
/// balance verified); the wallet tables were never copied, so their rows are
/// gone for good. Nothing else is touched: `document_files` keeps every file
/// (book attachments point at them), and `attachment_refs` stays because
/// expense attachments still use it.
///
/// `expenses` must be rebuilt first. Its `account_id` column (family expenses)
/// has a foreign key to `personal_accounts`, and once that parent is dropped
/// SQLite refuses every later write to the child ("no such table"). Android 7's
/// SQLite (3.9) has no `DROP COLUMN`, so the table is copied without the
/// family columns, like [MigrationV6] did for `wallet_transactions`. Family
/// expenses simply become ordinary expenses.
///
/// A failure aborts startup on every launch, and the whole upgrade runs in one
/// transaction, so nothing here throws on odd data; the safety net is that
/// transaction plus the file snapshot taken before any upgrade.
final class MigrationV8 implements DatabaseMigration {
  const MigrationV8();

  /// Children first: `DROP TABLE` deletes the rows implicitly and the foreign
  /// keys (RESTRICT from payments and advances to wallets) must not object.
  static const List<String> droppedTables = <String>[
    'advance_payments',
    'debt_payments',
    'wallet_transactions',
    'advances',
    'debts',
    'wallets',
    'persons',
    'ledger_entries',
    'personal_accounts',
  ];

  @override
  int get version => 8;

  @override
  Future<void> apply(Transaction transaction) async {
    await _rebuildExpenses(transaction);
    // The trigger that used to clean these up goes with `ledger_entries`, and
    // an implicit delete during DROP TABLE fires no triggers.
    await transaction.execute(
      "DELETE FROM attachment_refs WHERE owner_type = 'ledger_entry'",
    );
    for (final table in droppedTables) {
      await transaction.execute('DROP TABLE IF EXISTS $table');
    }
  }

  Future<void> _rebuildExpenses(Transaction transaction) async {
    await transaction.execute('''
      CREATE TABLE expenses_new (
        id TEXT NOT NULL PRIMARY KEY,
        amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
        currency_code TEXT NOT NULL,
        category_id TEXT NOT NULL,
        expense_date INTEGER NOT NULL,
        title TEXT,
        notes TEXT,
        attachment_id TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY (category_id) REFERENCES expense_categories(id)
          ON DELETE RESTRICT,
        FOREIGN KEY (attachment_id) REFERENCES document_files(id)
          ON DELETE RESTRICT
      )
    ''');
    await transaction.execute('''
      INSERT INTO expenses_new
        (id, amount_minor, currency_code, category_id, expense_date, title,
         notes, attachment_id, created_at, updated_at)
      SELECT id, amount_minor, currency_code, category_id, expense_date, title,
         notes, attachment_id, created_at, updated_at
      FROM expenses
    ''');
    // Drops the table's indexes and its attachment-cleanup trigger with it.
    await transaction.execute('DROP TABLE expenses');
    await transaction.execute('ALTER TABLE expenses_new RENAME TO expenses');
    await transaction.execute(
      'CREATE INDEX idx_expenses_date ON expenses(expense_date DESC)',
    );
    await transaction.execute('''
      CREATE TRIGGER cleanup_expense_attachment_refs
      AFTER DELETE ON expenses
      BEGIN
        DELETE FROM attachment_refs
        WHERE owner_type = 'expense' AND owner_id = OLD.id;
      END
    ''');
  }
}
