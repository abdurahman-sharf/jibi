import 'package:sqflite/sqflite.dart';

import 'app_database.dart';

/// Schema v10: adds an optional phone number to `book_accounts`.
///
/// A book account often represents a person or a business the user tracks
/// debt with, and knowing how to reach them is useful (call/WhatsApp). Purely
/// additive, so no table rebuild is needed.
final class MigrationV10 implements DatabaseMigration {
  const MigrationV10();

  @override
  int get version => 10;

  @override
  Future<void> apply(Transaction transaction) async {
    await transaction.execute('ALTER TABLE book_accounts ADD COLUMN phone TEXT');
  }
}
