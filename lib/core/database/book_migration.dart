import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'app_database.dart';

/// Schema v7: the "مدونة الحسابات" (category > account > transaction) ledger.
///
/// Adds the `book_*` tables next to the legacy tables, which this migration
/// never touches (they are dropped later, by schema v8). Existing
/// `personal_accounts` / `ledger_entries` are copied into an active category so
/// the owner keeps every balance.
///
/// A failure aborts app startup on every launch (and Android cannot downgrade
/// the app), so the copy is deliberately defensive: odd rows are skipped or
/// repaired rather than thrown on, and only a proven balance mismatch throws,
/// which rolls the whole transaction back and leaves the database at v6.
///
/// The migration intentionally does not import the book domain code: a frozen
/// migration must not change behaviour when the app code evolves.
final class MigrationV7 implements DatabaseMigration {
  const MigrationV7();

  static const legacyCategoryId = 'legacy-people-category';
  static const legacyCategoryName = 'الأشخاص والسلف القديمة';

  @override
  int get version => 7;

  @override
  Future<void> apply(Transaction transaction) async {
    await _createSchema(transaction);
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _ensureCurrency(
      transaction,
      code: 'YER',
      name: 'ريال يمني',
      symbol: 'ر.ي',
      fractionDigits: 0,
      isActive: true,
      now: now,
    );
    await _LegacyLedgerMigrator(transaction, now).run();
  }

  static Future<void> _createSchema(Transaction txn) async {
    await txn.execute('''
      CREATE TABLE book_categories (
        id TEXT NOT NULL PRIMARY KEY,
        name TEXT NOT NULL,
        icon TEXT,
        description TEXT,
        sort_order INTEGER NOT NULL DEFAULT 0,
        is_active INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
        is_archived INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0, 1)),
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await txn.execute('''
      CREATE TABLE book_accounts (
        id TEXT NOT NULL PRIMARY KEY,
        category_id TEXT NOT NULL
          REFERENCES book_categories(id) ON DELETE RESTRICT,
        name TEXT NOT NULL,
        currency_code TEXT NOT NULL
          REFERENCES currencies(code) ON DELETE RESTRICT,
        opening_minor INTEGER NOT NULL DEFAULT 0 CHECK (opening_minor >= 0),
        opening_type TEXT NOT NULL DEFAULT 'ZERO'
          CHECK (opening_type IN ('DEBIT', 'CREDIT', 'ZERO')),
        notes TEXT,
        status TEXT NOT NULL DEFAULT 'active'
          CHECK (status IN ('active', 'suspended', 'archived')),
        sort_order INTEGER NOT NULL DEFAULT 0,
        legacy_account_id TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await txn.execute('''
      CREATE TABLE book_transactions (
        id TEXT NOT NULL PRIMARY KEY,
        transaction_number TEXT NOT NULL UNIQUE,
        account_id TEXT NOT NULL
          REFERENCES book_accounts(id) ON DELETE RESTRICT,
        type TEXT NOT NULL CHECK (type IN ('DEBIT', 'CREDIT')),
        amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
        transaction_date TEXT NOT NULL,
        transaction_time TEXT NOT NULL DEFAULT '00:00',
        details TEXT,
        notes TEXT,
        balance_after INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        deleted_at INTEGER
      )
    ''');
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
      CREATE TABLE book_audit_log (
        id TEXT NOT NULL PRIMARY KEY,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        action TEXT NOT NULL,
        details TEXT,
        created_at INTEGER NOT NULL
      )
    ''');
    await txn.execute('''
      CREATE TABLE book_counters (
        name TEXT NOT NULL PRIMARY KEY,
        value INTEGER NOT NULL
      )
    ''');
    await txn.execute(
      'CREATE INDEX idx_book_accounts_category ON book_accounts(category_id)',
    );
    await txn.execute(
      'CREATE INDEX idx_book_tx_account_date ON book_transactions('
      'account_id, transaction_date, transaction_time)',
    );
    await txn.execute(
      'CREATE INDEX idx_book_tx_account_type '
      'ON book_transactions(account_id, type)',
    );
    await txn.execute(
      'CREATE INDEX idx_book_tx_date ON book_transactions(transaction_date)',
    );
    await txn.execute(
      'CREATE INDEX idx_book_attachments_tx ON book_attachments(transaction_id)',
    );
    await txn.execute(
      'CREATE INDEX idx_book_audit_entity '
      'ON book_audit_log(entity_type, entity_id)',
    );
  }

  static Future<void> _ensureCurrency(
    Transaction txn, {
    required String code,
    required String name,
    required String symbol,
    required int fractionDigits,
    required bool isActive,
    required int now,
  }) async {
    await txn.rawInsert(
      'INSERT OR IGNORE INTO currencies '
      '(code, name, symbol, fraction_digits, sort_order, is_active, '
      'created_at, updated_at) '
      'VALUES (?, ?, ?, ?, '
      '(SELECT COALESCE(MAX(sort_order), -1) + 1 FROM currencies), ?, ?, ?)',
      <Object?>[
        code,
        name,
        symbol,
        fractionDigits,
        isActive ? 1 : 0,
        now,
        now,
      ],
    );
  }
}

/// Copies the legacy ledger into the book tables inside the caller's
/// transaction and proves the result with an independent SQL check.
final class _LegacyLedgerMigrator {
  _LegacyLedgerMigrator(this._txn, this._now);

  final Transaction _txn;
  final int _now;

  static const _legacyTypeLabels = <String, String>{
    'loanGiven': 'سلفة أعطيتها',
    'loanTaken': 'سلفة أخذتها',
    'paymentReceived': 'استلام مبلغ',
    'paymentMade': 'دفع مبلغ',
    'adjustment': 'تعديل يدوي',
  };

  /// Same signs as the legacy `BalanceEngine.signedAmount`; null when the type
  /// is unknown (the legacy app could not read such a row either).
  static int? _signed(String type, int amount) => switch (type) {
    'loanGiven' || 'paymentMade' || 'adjustment' => amount,
    'loanTaken' || 'paymentReceived' => -amount,
    _ => null,
  };

  Future<void> run() async {
    final accounts = await _txn.query(
      'personal_accounts',
      orderBy: 'created_at ASC, name ASC, id ASC',
    );
    if (accounts.isEmpty) {
      return;
    }
    final entryRows = await _txn.query('ledger_entries');

    final entries = <_LegacyEntry>[
      for (final row in entryRows) _LegacyEntry.fromRow(row),
    ];

    // The legacy table has no FK on currency_code but the new one does, so any
    // code missing from `currencies` is registered (inactive) first.
    final codesInUse = <String>{for (final entry in entries) entry.currency};
    for (final code in codesInUse) {
      await MigrationV7._ensureCurrency(
        _txn,
        code: code,
        name: code,
        symbol: code,
        fractionDigits: 2,
        isActive: false,
        now: _now,
      );
    }
    final fallbackCurrency = await _fallbackCurrency();

    // One book account per (legacy account x currency).
    final currenciesByAccount = <String, Set<String>>{};
    for (final entry in entries) {
      currenciesByAccount
          .putIfAbsent(entry.accountId, () => <String>{})
          .add(entry.currency);
    }

    final batch = _txn.batch();
    batch.insert('book_categories', <String, Object?>{
      'id': MigrationV7.legacyCategoryId,
      'name': MigrationV7.legacyCategoryName,
      'icon': 'people',
      'description': 'حسابات وسلف نُقلت من النظام السابق.',
      'sort_order': 0,
      'is_active': 1,
      'is_archived': 0,
      'created_at': _now,
      'updated_at': _now,
    });

    final bookAccounts = <_BookAccount>[];
    var accountOrder = 0;
    for (final row in accounts) {
      final legacyId = row['id']! as String;
      final name = (row['name'] as String?)?.trim();
      final baseName = (name == null || name.isEmpty) ? 'حساب بلا اسم' : name;
      final currencies = (currenciesByAccount[legacyId] ?? <String>{})
          .toList()
        ..sort();
      if (currencies.isEmpty) {
        currencies.add(fallbackCurrency);
      }
      final phone = (row['phone'] as String?)?.trim();
      final notes = (row['notes'] as String?)?.trim();
      final combinedNotes = <String>[
        if (phone != null && phone.isNotEmpty) 'الهاتف: $phone',
        if (notes != null && notes.isNotEmpty) notes,
      ].join('\n');
      for (final currency in currencies) {
        final account = _BookAccount(
          id: 'legacy-$legacyId-$currency',
          legacyId: legacyId,
          currency: currency,
        );
        bookAccounts.add(account);
        batch.insert('book_accounts', <String, Object?>{
          'id': account.id,
          'category_id': MigrationV7.legacyCategoryId,
          'name': currencies.length > 1 ? '$baseName ($currency)' : baseName,
          'currency_code': currency,
          'opening_minor': 0,
          'opening_type': 'ZERO',
          'notes': combinedNotes.isEmpty ? null : combinedNotes,
          'status': (row['is_archived'] as int? ?? 0) == 1
              ? 'archived'
              : 'active',
          'sort_order': accountOrder++,
          'legacy_account_id': legacyId,
          'created_at': row['created_at'] as int? ?? _now,
          'updated_at': row['updated_at'] as int? ?? _now,
        });
      }
    }
    final accountById = <String, _BookAccount>{
      for (final account in bookAccounts) account.id: account,
    };

    // Transactions: skipped rows are unknown types or zero amounts (the new
    // table requires amount > 0); both contribute nothing to a balance.
    final migrated = <_LegacyEntry>[
      for (final entry in entries)
        if ((entry.signed ?? 0) != 0 &&
            accountById.containsKey('legacy-${entry.accountId}-${entry.currency}'))
          entry,
    ]..sort(_LegacyEntry.compareChronologically);

    final runningBalance = <String, int>{};
    var number = 0;
    for (final entry in migrated) {
      number++;
      final bookAccountId = 'legacy-${entry.accountId}-${entry.currency}';
      final signed = entry.signed!;
      final balance = (runningBalance[bookAccountId] ?? 0) + signed;
      runningBalance[bookAccountId] = balance;
      batch.insert('book_transactions', <String, Object?>{
        'id': entry.id,
        'transaction_number': _formatNumber(number),
        'account_id': bookAccountId,
        'type': signed > 0 ? 'DEBIT' : 'CREDIT',
        'amount_minor': signed.abs(),
        'transaction_date': entry.date,
        'transaction_time': entry.time,
        'details': _legacyTypeLabels[entry.type],
        'notes': entry.notes,
        'balance_after': balance,
        'created_at': entry.createdAt,
        'updated_at': entry.updatedAt,
      });
    }
    batch.insert('book_counters', <String, Object?>{
      'name': 'tx_number',
      'value': number,
    });

    await _addAttachments(batch, migrated);
    await batch.commit(noResult: true);
    await _verify(accounts: bookAccounts);
  }

  /// The real source of a legacy attachment is `ledger_entries.attachment_id`;
  /// `attachment_refs` only complements it. Both are migrated (distinct pairs)
  /// as references to the untouched `document_files` rows.
  Future<void> _addAttachments(Batch batch, List<_LegacyEntry> migrated) async {
    final files = <String, Map<String, Object?>>{
      for (final row in await _txn.query('document_files'))
        row['id']! as String: row,
    };
    final refs = await _txn.query(
      'attachment_refs',
      where: "owner_type = 'ledger_entry'",
    );
    final fileIdsByEntry = <String, Set<String>>{};
    for (final ref in refs) {
      fileIdsByEntry
          .putIfAbsent(ref['owner_id']! as String, () => <String>{})
          .add(ref['document_file_id']! as String);
    }
    for (final entry in migrated) {
      final ids = <String>{
        ...?fileIdsByEntry[entry.id],
        if (entry.attachmentId != null) entry.attachmentId!,
      };
      for (final fileId in ids) {
        final file = files[fileId];
        if (file == null) {
          continue;
        }
        final mime = (file['mime_type'] as String?) ?? 'application/octet-stream';
        final extension = (file['original_extension'] as String?) ?? '';
        batch.insert('book_attachments', <String, Object?>{
          'id': 'legacy-att-${entry.id}-$fileId',
          'transaction_id': entry.id,
          'kind': _kindFor(mime),
          'file_name': extension.isEmpty ? 'مرفق' : 'مرفق.$extension',
          'mime_type': mime,
          'encrypted_file_name': null,
          'original_extension': extension.isEmpty ? null : extension,
          'file_size': file['encrypted_size'] as int? ?? 0,
          'checksum': file['checksum'],
          'document_file_id': fileId,
          'created_at': file['created_at'] as int? ?? _now,
        });
      }
    }
  }

  static String _kindFor(String mime) {
    if (mime.startsWith('image/')) {
      return 'image';
    }
    if (mime == 'application/pdf') {
      return 'pdf';
    }
    return 'document';
  }

  /// Independent SQL check (a different code path from the Dart conversion):
  /// the legacy signed sum and row count of every (account x currency) must
  /// equal the migrated sum, count and final `balance_after`.
  Future<void> _verify({required List<_BookAccount> accounts}) async {
    final legacy = await _txn.rawQuery('''
      SELECT account_id, currency_code,
        COALESCE(SUM(CASE entry_type
          WHEN 'loanGiven' THEN amount_minor
          WHEN 'paymentMade' THEN amount_minor
          WHEN 'adjustment' THEN amount_minor
          WHEN 'loanTaken' THEN -amount_minor
          WHEN 'paymentReceived' THEN -amount_minor
          ELSE 0 END), 0) AS net,
        COALESCE(SUM(CASE WHEN amount_minor != 0 AND entry_type IN
          ('loanGiven','paymentMade','adjustment','loanTaken','paymentReceived')
          THEN 1 ELSE 0 END), 0) AS cnt
      FROM ledger_entries
      WHERE account_id IN (SELECT id FROM personal_accounts)
      GROUP BY account_id, currency_code
    ''');
    final migrated = await _txn.rawQuery('''
      SELECT a.id AS id,
        COALESCE(SUM(CASE t.type WHEN 'DEBIT' THEN t.amount_minor
          ELSE -t.amount_minor END), 0) AS net,
        COUNT(t.id) AS cnt
      FROM book_accounts a
      LEFT JOIN book_transactions t ON t.account_id = a.id
      WHERE a.legacy_account_id IS NOT NULL
      GROUP BY a.id
    ''');
    final migratedById = <String, Map<String, Object?>>{
      for (final row in migrated) row['id']! as String: row,
    };
    for (final row in legacy) {
      final id = 'legacy-${row['account_id']}-${row['currency_code']}';
      final actual = migratedById[id];
      if (actual == null ||
          actual['net'] != row['net'] ||
          actual['cnt'] != row['cnt']) {
        throw StateError(
          'legacy_migration_mismatch: $id legacy=$row migrated=$actual',
        );
      }
    }
    for (final account in accounts) {
      final expectedNet = migratedById[account.id]!['net'];
      final last = await _txn.rawQuery(
        'SELECT balance_after FROM book_transactions WHERE account_id = ? '
        'ORDER BY transaction_date DESC, transaction_time DESC, '
        'created_at DESC, id DESC LIMIT 1',
        <Object?>[account.id],
      );
      final finalBalance = last.isEmpty ? 0 : last.single['balance_after'];
      if (finalBalance != expectedNet) {
        throw StateError(
          'legacy_migration_balance_after_mismatch: ${account.id} '
          'expected=$expectedNet actual=$finalBalance',
        );
      }
    }
  }

  /// Currency for legacy accounts that never had an entry: the saved default
  /// when it still exists, else the first active currency, else SAR.
  Future<String> _fallbackCurrency() async {
    String? saved;
    try {
      final rows = await _txn.query(
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
      final exists = await _txn.query(
        'currencies',
        columns: <String>['code'],
        where: 'code = ?',
        whereArgs: <Object?>[saved],
      );
      if (exists.isNotEmpty) {
        return saved;
      }
    }
    final first = await _txn.query(
      'currencies',
      columns: <String>['code'],
      where: 'is_active = 1',
      orderBy: 'sort_order ASC, code ASC',
      limit: 1,
    );
    if (first.isNotEmpty) {
      return first.single['code']! as String;
    }
    await MigrationV7._ensureCurrency(
      _txn,
      code: 'SAR',
      name: 'ريال سعودي',
      symbol: 'ر.س',
      fractionDigits: 2,
      isActive: true,
      now: _now,
    );
    return 'SAR';
  }

  static String _formatNumber(int value) =>
      'TX-${value.toString().padLeft(6, '0')}';
}

final class _BookAccount {
  const _BookAccount({
    required this.id,
    required this.legacyId,
    required this.currency,
  });

  final String id;
  final String legacyId;
  final String currency;
}

final class _LegacyEntry {
  _LegacyEntry({
    required this.id,
    required this.accountId,
    required this.type,
    required this.currency,
    required this.signed,
    required this.date,
    required this.time,
    required this.notes,
    required this.attachmentId,
    required this.createdAt,
    required this.updatedAt,
  });

  factory _LegacyEntry.fromRow(Map<String, Object?> row) {
    final occurredAt = row['transaction_date'] as int? ?? 0;
    final local = DateTime.fromMillisecondsSinceEpoch(
      occurredAt,
      isUtc: true,
    ).toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    final type = row['entry_type']! as String;
    final amount = row['amount_minor'] as int? ?? 0;
    final notes = (row['notes'] as String?)?.trim();
    return _LegacyEntry(
      id: row['id']! as String,
      accountId: row['account_id']! as String,
      type: type,
      currency: (row['currency_code']! as String).toUpperCase(),
      signed: _LegacyLedgerMigrator._signed(type, amount),
      date:
          '${local.year.toString().padLeft(4, '0')}-${two(local.month)}-'
          '${two(local.day)}',
      time: '${two(local.hour)}:${two(local.minute)}',
      notes: (notes == null || notes.isEmpty) ? null : notes,
      attachmentId: row['attachment_id'] as String?,
      createdAt: row['created_at'] as int? ?? 0,
      updatedAt: row['updated_at'] as int? ?? 0,
    );
  }

  final String id;
  final String accountId;
  final String type;
  final String currency;
  final int? signed;
  final String date;
  final String time;
  final String? notes;
  final String? attachmentId;
  final int createdAt;
  final int updatedAt;

  /// Same key the book repository uses to order an account's transactions.
  static int compareChronologically(_LegacyEntry a, _LegacyEntry b) {
    var order = a.date.compareTo(b.date);
    if (order != 0) return order;
    order = a.time.compareTo(b.time);
    if (order != 0) return order;
    order = a.createdAt.compareTo(b.createdAt);
    if (order != 0) return order;
    return a.id.compareTo(b.id);
  }
}
