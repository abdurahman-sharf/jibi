import 'dart:io';

import 'package:sqflite/sqflite.dart';

import '../errors/app_exception.dart';
import 'book_account_phone_migration.dart';
import 'book_migration.dart';
import 'currency_defaults_migration.dart';
import 'expenses_removal_migration.dart';
import 'legacy_cleanup_migration.dart';
import 'multi_currency_accounts_migration.dart';
import 'multi_currency_wallets_migration.dart';
import 'wallets_migration.dart';

export 'book_account_phone_migration.dart' show MigrationV10;
export 'book_migration.dart' show MigrationV7;
export 'currency_defaults_migration.dart' show MigrationV13;
export 'expenses_removal_migration.dart' show MigrationV9;
export 'legacy_cleanup_migration.dart' show MigrationV8;
export 'multi_currency_accounts_migration.dart' show MigrationV14;
export 'multi_currency_wallets_migration.dart' show MigrationV12;
export 'wallets_migration.dart' show MigrationV11;

/// A single, append-only database migration.
abstract interface class DatabaseMigration {
  int get version;
  Future<void> apply(Transaction transaction);
}

final class MigrationV4 implements DatabaseMigration {
  const MigrationV4();
  @override
  int get version => 4;
  @override
  Future<void> apply(Transaction transaction) async {
    await transaction.execute(
      'ALTER TABLE expenses ADD COLUMN account_id TEXT REFERENCES personal_accounts(id) ON DELETE SET NULL',
    );
    await transaction.execute(
      "ALTER TABLE expenses ADD COLUMN expense_kind TEXT NOT NULL DEFAULT 'general' CHECK (expense_kind IN ('general', 'family'))",
    );
    await transaction.execute(
      'CREATE INDEX idx_expenses_account ON expenses(account_id)',
    );
  }
}

final class MigrationV5 implements DatabaseMigration {
  const MigrationV5();
  @override
  int get version => 5;
  @override
  Future<void> apply(Transaction transaction) async {
    await transaction.execute('''
      CREATE TABLE wallets (
        id TEXT NOT NULL PRIMARY KEY,
        name TEXT NOT NULL,
        type TEXT NOT NULL,
        currency_code TEXT NOT NULL REFERENCES currencies(code) ON DELETE RESTRICT,
        opening_minor INTEGER NOT NULL DEFAULT 0,
        icon TEXT,
        color TEXT,
        notes TEXT,
        status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','hidden','archived')),
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await transaction.execute('''
      CREATE TABLE persons (
        id TEXT NOT NULL PRIMARY KEY,
        name TEXT NOT NULL,
        phone TEXT,
        avatar_path TEXT,
        notes TEXT,
        is_archived INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0, 1)),
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await transaction.execute('''
      CREATE TABLE wallet_transactions (
        id TEXT NOT NULL PRIMARY KEY,
        type TEXT NOT NULL CHECK (type IN ('expense','income','transfer','advance','advanceCollection','debt','debtPayment','balanceAdjustment')),
        amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
        currency_code TEXT NOT NULL,
        wallet_id TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
        to_wallet_id TEXT REFERENCES wallets(id) ON DELETE RESTRICT,
        person_id TEXT REFERENCES persons(id) ON DELETE SET NULL,
        category_id TEXT REFERENCES expense_categories(id) ON DELETE SET NULL,
        advance_id TEXT,
        debt_id TEXT,
        occurred_at INTEGER NOT NULL,
        notes TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        CHECK (to_wallet_id IS NULL OR type = 'transfer'),
        CHECK (wallet_id != to_wallet_id)
      )
    ''');
    await transaction.execute('''
      CREATE TABLE advances (
        id TEXT NOT NULL PRIMARY KEY,
        person_id TEXT NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
        src_wallet_id TEXT NOT NULL REFERENCES wallets(id) ON DELETE RESTRICT,
        total_minor INTEGER NOT NULL CHECK (total_minor > 0),
        collected_minor INTEGER NOT NULL DEFAULT 0 CHECK (collected_minor >= 0),
        due_date INTEGER,
        status TEXT NOT NULL DEFAULT 'active',
        description TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        CHECK (collected_minor <= total_minor)
      )
    ''');
    await transaction.execute('''
      CREATE TABLE debts (
        id TEXT NOT NULL PRIMARY KEY,
        person_id TEXT NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
        dest_wallet_id TEXT REFERENCES wallets(id) ON DELETE RESTRICT,
        total_minor INTEGER NOT NULL CHECK (total_minor > 0),
        paid_minor INTEGER NOT NULL DEFAULT 0 CHECK (paid_minor >= 0),
        due_date INTEGER,
        status TEXT NOT NULL DEFAULT 'active',
        description TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        CHECK (paid_minor <= total_minor)
      )
    ''');
    await transaction.execute('''
      CREATE TABLE advance_payments (
        id TEXT NOT NULL PRIMARY KEY,
        advance_id TEXT NOT NULL REFERENCES advances(id) ON DELETE CASCADE,
        amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
        wallet_id TEXT NOT NULL REFERENCES wallets(id) ON DELETE RESTRICT,
        occurred_at INTEGER NOT NULL,
        method TEXT,
        notes TEXT,
        created_at INTEGER NOT NULL
      )
    ''');
    await transaction.execute('''
      CREATE TABLE debt_payments (
        id TEXT NOT NULL PRIMARY KEY,
        debt_id TEXT NOT NULL REFERENCES debts(id) ON DELETE CASCADE,
        amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
        wallet_id TEXT NOT NULL REFERENCES wallets(id) ON DELETE RESTRICT,
        occurred_at INTEGER NOT NULL,
        method TEXT,
        notes TEXT,
        created_at INTEGER NOT NULL
      )
    ''');
    await transaction.execute('CREATE INDEX idx_wtx_wallet_date ON wallet_transactions(wallet_id, occurred_at DESC)');
    await transaction.execute('CREATE INDEX idx_wtx_person ON wallet_transactions(person_id)');
    await transaction.execute('CREATE INDEX idx_adv_person ON advances(person_id)');
    await transaction.execute('CREATE INDEX idx_debt_due ON debts(due_date)');
  }
}

final class MigrationV6 implements DatabaseMigration {
  const MigrationV6();
  @override
  int get version => 6;
  @override
  Future<void> apply(Transaction transaction) async {
    await transaction.execute(
      "ALTER TABLE advances ADD COLUMN currency_code TEXT NOT NULL DEFAULT 'SAR'",
    );
    await transaction.execute(
      "ALTER TABLE debts ADD COLUMN currency_code TEXT NOT NULL DEFAULT 'SAR'",
    );
    await transaction.execute('''
      CREATE TABLE wallet_transactions_new (
        id TEXT NOT NULL PRIMARY KEY,
        type TEXT NOT NULL CHECK (type IN ('expense','income','transfer','advance','advanceCollection','debt','debtPayment','balanceAdjustment')),
        amount_minor INTEGER NOT NULL CHECK (amount_minor > 0 OR (type = 'balanceAdjustment' AND amount_minor != 0)),
        currency_code TEXT NOT NULL,
        wallet_id TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
        to_wallet_id TEXT REFERENCES wallets(id) ON DELETE RESTRICT,
        person_id TEXT REFERENCES persons(id) ON DELETE SET NULL,
        category_id TEXT REFERENCES expense_categories(id) ON DELETE SET NULL,
        advance_id TEXT,
        debt_id TEXT,
        occurred_at INTEGER NOT NULL,
        notes TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        CHECK (to_wallet_id IS NULL OR type = 'transfer'),
        CHECK (wallet_id != to_wallet_id)
      )
    ''');
    await transaction.execute('''
      INSERT INTO wallet_transactions_new
        (id, type, amount_minor, currency_code, wallet_id, to_wallet_id,
         person_id, category_id, advance_id, debt_id,
         occurred_at, notes, created_at, updated_at)
      SELECT id, type, amount_minor, currency_code, wallet_id, to_wallet_id,
         person_id, category_id, advance_id, debt_id,
         occurred_at, notes, created_at, updated_at
      FROM wallet_transactions
    ''');
    await transaction.execute('DROP TABLE wallet_transactions');
    await transaction.execute(
      'ALTER TABLE wallet_transactions_new RENAME TO wallet_transactions',
    );
    await transaction.execute(
      'CREATE INDEX idx_wtx_wallet_date ON wallet_transactions(wallet_id, occurred_at DESC)',
    );
    await transaction.execute(
      'CREATE INDEX idx_wtx_person ON wallet_transactions(person_id)',
    );
  }
}

final class AppDatabase {
  AppDatabase({
    required this.path,
    Iterable<DatabaseMigration> migrations = const [
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
      MigrationV13(),
      MigrationV14(),
    ],
  }) : _migrations = _validatedMigrations(migrations);

  static const int schemaVersion = 14;

  /// How many pre-upgrade snapshots are kept next to the database.
  static const int retainedSnapshots = 2;

  final String path;
  final List<DatabaseMigration> _migrations;
  Database? _database;
  Future<Database>? _opening;

  /// File name of the snapshot taken by the last upgrade of this instance, if
  /// one was needed.
  String? snapshotFileName;

  Future<Database> get database async {
    final cached = _database;
    if (cached != null && cached.isOpen) {
      return cached;
    }
    // Concurrent first callers share one open so the snapshot and the
    // migration can never run twice at the same time.
    return _opening ??= _open().whenComplete(() => _opening = null);
  }

  Future<Database> _open() async {
    try {
      final opened = await openDatabase(
        path,
        version: schemaVersion,
        onConfigure: (database) async {
          await database.execute('PRAGMA foreign_keys = ON');
          await _snapshotBeforeUpgrade(database);
        },
        onCreate: (database, version) => _migrate(database, 0, version),
        onUpgrade: _migrate,
      );
      _database = opened;
      return opened;
    } on AppException {
      rethrow;
    } on Object catch (error) {
      if (snapshotFileName == null) {
        rethrow;
      }
      // The upgrade ran in one transaction, so the old database is untouched.
      throw StorageException(
        code: 'database_migration_failed',
        userMessage:
            'تعذر تحديث قاعدة البيانات إلى الإصدار الجديد. بياناتك سليمة '
            'ولم تتغير. حدّث التطبيق إلى أحدث نسخة أو راجع المطوّر.',
        cause: error,
      );
    }
  }

  /// Copies the database file before an upgrade runs.
  ///
  /// Runs from `onConfigure`, which sqflite invokes on the already open
  /// connection before it reads the version and outside the migration
  /// transaction, so the file is never opened twice.
  Future<void> _snapshotBeforeUpgrade(Database database) async {
    if (path == inMemoryDatabasePath) {
      return;
    }
    final version = await database.getVersion();
    if (version == 0 || version >= schemaVersion) {
      return;
    }
    try {
      await database.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
      final source = File(path);
      final name =
          '${source.uri.pathSegments.last}.pre-v$schemaVersion-'
          '${DateTime.now().toUtc().millisecondsSinceEpoch}.bak';
      final target = File('${source.parent.path}${Platform.pathSeparator}$name');
      await source.copy(target.path);
      final copied = await target.length();
      final header = await target.openRead(0, 16).first;
      if (copied != await source.length() ||
          String.fromCharCodes(header.take(15)) != 'SQLite format 3') {
        await target.delete();
        throw const StorageException(
          code: 'migration_snapshot_invalid',
          userMessage: 'تعذر التحقق من نسخة الأمان.',
        );
      }
      snapshotFileName = name;
      await _pruneSnapshots(source);
    } on AppException {
      rethrow;
    } on Object catch (error) {
      throw StorageException(
        code: 'migration_snapshot_failed',
        userMessage:
            'تعذر إنشاء نسخة أمان قبل تحديث قاعدة البيانات، ولم تتغير أي '
            'بيانات. تأكد من توفر مساحة كافية ثم أعد المحاولة.',
        cause: error,
      );
    }
  }

  Future<void> _pruneSnapshots(File database) async {
    final prefix = '${database.uri.pathSegments.last}.pre-v';
    final snapshots = <File>[
      await for (final entity in database.parent.list(followLinks: false))
        if (entity is File &&
            entity.uri.pathSegments.last.startsWith(prefix) &&
            entity.path.endsWith('.bak'))
          entity,
    ];
    if (snapshots.length <= retainedSnapshots) {
      return;
    }
    // The name ends with the epoch milliseconds, so lexical order per version
    // is chronological; sort by modification time to stay version agnostic.
    final withTimes = <(File, DateTime)>[
      for (final file in snapshots) (file, await file.lastModified()),
    ]..sort((left, right) => right.$2.compareTo(left.$2));
    for (final stale in withTimes.skip(retainedSnapshots)) {
      await stale.$1.delete();
    }
  }

  Future<void> close() async {
    final database = _database;
    _database = null;
    await database?.close();
  }

  Future<void> _migrate(Database database, int from, int to) async {
    await database.transaction((transaction) async {
      for (final migration in _migrations) {
        if (migration.version > from && migration.version <= to) {
          await migration.apply(transaction);
        }
      }
    });
  }

  static List<DatabaseMigration> _validatedMigrations(
    Iterable<DatabaseMigration> migrations,
  ) {
    final sorted = migrations.toList()
      ..sort((left, right) => left.version.compareTo(right.version));
    for (var index = 0; index < sorted.length; index++) {
      if (sorted[index].version != index + 1) {
        throw ArgumentError.value(
          migrations,
          'migrations',
          'Migrations must start at 1 and be contiguous.',
        );
      }
    }
    if (sorted.length != schemaVersion) {
      throw ArgumentError.value(
        migrations,
        'migrations',
        'Provide exactly one migration per schema version.',
      );
    }
    return List<DatabaseMigration>.unmodifiable(sorted);
  }
}

/// Initial foundation. Feature migrations are appended; existing migrations
/// are never modified or replaced with a database drop.
final class MigrationV1 implements DatabaseMigration {
  const MigrationV1();

  @override
  int get version => 1;

  @override
  Future<void> apply(Transaction transaction) async {
    await transaction.execute('''
      CREATE TABLE app_settings (
        key TEXT NOT NULL PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
  }
}

/// Adds the MVP's persisted entities. Sensitive vault and document metadata
/// columns contain only application-layer ciphertext envelopes.
final class MigrationV2 implements DatabaseMigration {
  const MigrationV2();

  @override
  int get version => 2;

  @override
  Future<void> apply(Transaction transaction) async {
    await transaction.execute('''
      CREATE TABLE personal_accounts (
        id TEXT NOT NULL PRIMARY KEY,
        name TEXT NOT NULL,
        phone TEXT,
        avatar_path TEXT,
        notes TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        is_archived INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0, 1))
      )
    ''');
    await transaction.execute('''
      CREATE TABLE expense_categories (
        id TEXT NOT NULL PRIMARY KEY,
        name TEXT NOT NULL,
        icon TEXT,
        created_at INTEGER NOT NULL,
        is_default INTEGER NOT NULL DEFAULT 0 CHECK (is_default IN (0, 1))
      )
    ''');
    await transaction.execute('''
      CREATE TABLE document_categories (
        id TEXT NOT NULL PRIMARY KEY,
        name TEXT NOT NULL,
        icon TEXT
      )
    ''');
    await transaction.execute('''
      CREATE TABLE tags (
        id TEXT NOT NULL PRIMARY KEY,
        name TEXT NOT NULL
      )
    ''');
    await transaction.execute('''
      CREATE TABLE documents (
        id TEXT NOT NULL PRIMARY KEY,
        title TEXT NOT NULL,
        category_id TEXT,
        document_number_encrypted TEXT,
        issuer_encrypted TEXT,
        issue_date INTEGER,
        expiry_date INTEGER,
        notes_encrypted TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY (category_id) REFERENCES document_categories(id)
          ON DELETE SET NULL
      )
    ''');
    await transaction.execute('''
      CREATE TABLE document_tags (
        document_id TEXT NOT NULL,
        tag_id TEXT NOT NULL,
        PRIMARY KEY (document_id, tag_id),
        FOREIGN KEY (document_id) REFERENCES documents(id) ON DELETE CASCADE,
        FOREIGN KEY (tag_id) REFERENCES tags(id) ON DELETE RESTRICT
      )
    ''');
    await transaction.execute('''
      CREATE TABLE document_files (
        id TEXT NOT NULL PRIMARY KEY,
        document_id TEXT NOT NULL,
        encrypted_file_name TEXT NOT NULL UNIQUE,
        original_extension TEXT NOT NULL,
        mime_type TEXT NOT NULL,
        encrypted_size INTEGER NOT NULL CHECK (encrypted_size >= 0),
        checksum TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        FOREIGN KEY (document_id) REFERENCES documents(id) ON DELETE CASCADE
      )
    ''');
    await transaction.execute('''
      CREATE TABLE ledger_entries (
        id TEXT NOT NULL PRIMARY KEY,
        account_id TEXT NOT NULL,
        entry_type TEXT NOT NULL,
        amount_minor INTEGER NOT NULL,
        currency_code TEXT NOT NULL,
        transaction_date INTEGER NOT NULL,
        notes TEXT,
        attachment_id TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY (account_id) REFERENCES personal_accounts(id)
          ON DELETE CASCADE,
        FOREIGN KEY (attachment_id) REFERENCES document_files(id)
          ON DELETE RESTRICT
      )
    ''');
    await transaction.execute('''
      CREATE TABLE expenses (
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
      CREATE TABLE credentials (
        id TEXT NOT NULL PRIMARY KEY,
        title TEXT NOT NULL,
        username_encrypted TEXT NOT NULL,
        email_encrypted TEXT NOT NULL,
        password_encrypted TEXT NOT NULL,
        url TEXT,
        notes_encrypted TEXT NOT NULL,
        category_id TEXT,
        is_favorite INTEGER NOT NULL DEFAULT 0 CHECK (is_favorite IN (0, 1)),
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await transaction.execute('''
      CREATE TABLE credential_categories (
        id TEXT NOT NULL PRIMARY KEY,
        name TEXT NOT NULL,
        icon TEXT
      )
    ''');
    await transaction.execute('''
      CREATE TABLE attachment_refs (
        id TEXT NOT NULL PRIMARY KEY,
        owner_type TEXT NOT NULL,
        owner_id TEXT NOT NULL,
        document_file_id TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        UNIQUE (owner_type, owner_id),
        FOREIGN KEY (document_file_id) REFERENCES document_files(id)
          ON DELETE RESTRICT
      )
    ''');
    await transaction.execute('''
      CREATE TABLE backup_history (
        id TEXT NOT NULL PRIMARY KEY,
        drive_file_id TEXT,
        created_at INTEGER NOT NULL,
        size INTEGER NOT NULL,
        backup_version INTEGER NOT NULL,
        status TEXT NOT NULL
      )
    ''');

    await transaction.execute(
      'CREATE INDEX idx_ledger_account_date '
      'ON ledger_entries(account_id, transaction_date DESC)',
    );
    await transaction.execute(
      'CREATE INDEX idx_expenses_date ON expenses(expense_date DESC)',
    );
    await transaction.execute(
      'CREATE INDEX idx_document_files_document ON document_files(document_id)',
    );
    await transaction.execute(
      'CREATE INDEX idx_attachment_refs_file '
      'ON attachment_refs(document_file_id)',
    );
    await transaction.execute('''
      CREATE TRIGGER cleanup_ledger_attachment_refs
      AFTER DELETE ON ledger_entries
      BEGIN
        DELETE FROM attachment_refs
        WHERE owner_type = 'ledger_entry' AND owner_id = OLD.id;
      END
    ''');
    await transaction.execute('''
      CREATE TRIGGER cleanup_expense_attachment_refs
      AFTER DELETE ON expenses
      BEGIN
        DELETE FROM attachment_refs
        WHERE owner_type = 'expense' AND owner_id = OLD.id;
      END
    ''');

    for (final category in const <(String, String)>[
      ('food', 'طعام'),
      ('transport', 'مواصلات'),
      ('home', 'منزل'),
      ('shopping', 'تسوق'),
      ('bills', 'فواتير'),
      ('health', 'صحة'),
      ('travel', 'سفر'),
      ('entertainment', 'ترفيه'),
      ('education', 'تعليم'),
      ('other', 'أخرى'),
    ]) {
      await transaction.insert('expense_categories', <String, Object?>{
        'id': category.$1,
        'name': category.$2,
        'created_at': DateTime.now().toUtc().millisecondsSinceEpoch,
        'is_default': 1,
      });
    }
  }
}

/// Moves currencies from the hardcoded registry into a managed table so they
/// can be added, renamed, reordered, and archived from the app.
final class MigrationV3 implements DatabaseMigration {
  const MigrationV3();

  @override
  int get version => 3;

  @override
  Future<void> apply(Transaction transaction) async {
    await transaction.execute('''
      CREATE TABLE currencies (
        code TEXT NOT NULL PRIMARY KEY,
        name TEXT NOT NULL,
        symbol TEXT,
        fraction_digits INTEGER NOT NULL CHECK (fraction_digits BETWEEN 0 AND 3),
        sort_order INTEGER NOT NULL DEFAULT 0,
        is_active INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    for (final seed in const <(String, String, String, int)>[
      ('SAR', 'ريال سعودي', 'ر.س', 2),
      ('USD', 'دولار أمريكي', r'$', 2),
      ('EUR', 'يورو', '€', 2),
      ('AED', 'درهم إماراتي', 'د.إ', 2),
      ('KWD', 'دينار كويتي', 'د.ك', 3),
      ('BHD', 'دينار بحريني', 'د.ب', 3),
      ('OMR', 'ريال عماني', 'ر.ع', 3),
      ('QAR', 'ريال قطري', 'ر.ق', 2),
      ('GBP', 'جنيه إسترليني', '£', 2),
    ]) {
      final index = const <String>[
        'SAR',
        'USD',
        'EUR',
        'AED',
        'KWD',
        'BHD',
        'OMR',
        'QAR',
        'GBP',
      ].indexOf(seed.$1);
      await transaction.insert('currencies', <String, Object?>{
        'code': seed.$1,
        'name': seed.$2,
        'symbol': seed.$3,
        'fraction_digits': seed.$4,
        'sort_order': index,
        'is_active': 1,
        'created_at': now,
        'updated_at': now,
      });
    }
  }
}
