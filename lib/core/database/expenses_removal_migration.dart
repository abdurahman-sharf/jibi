import 'package:sqflite/sqflite.dart';

import 'app_database.dart';

/// Schema v9: removes the general expenses feature.
///
/// Expenses were a stand-alone list that never reached the accounts book, the
/// balances or the reports, so the feature was dropped: `expenses` and
/// `expense_categories` (with their indexes and the attachment-cleanup
/// trigger) go, and so do any `attachment_refs` rows owned by an expense.
///
/// Nothing else is touched. The expense form never attached files, so no
/// `document_files` row (or encrypted file) belongs to an expense; and
/// `attachment_refs` itself stays, because the documents feature uses it to
/// protect files that other items still point at.
///
/// The rows are gone for good after this runs. The safety net is the same as
/// for v8: the whole upgrade is one transaction, and a file snapshot of the
/// database is taken before any upgrade.
final class MigrationV9 implements DatabaseMigration {
  const MigrationV9();

  /// Child first: `expenses` has a RESTRICT foreign key to its categories.
  static const List<String> droppedTables = <String>[
    'expenses',
    'expense_categories',
  ];

  @override
  int get version => 9;

  @override
  Future<void> apply(Transaction transaction) async {
    // The trigger that used to clean these up goes with `expenses`, and an
    // implicit delete during DROP TABLE fires no triggers.
    await transaction.execute(
      "DELETE FROM attachment_refs WHERE owner_type = 'expense'",
    );
    for (final table in droppedTables) {
      await transaction.execute('DROP TABLE IF EXISTS $table');
    }
  }
}
