import 'dart:async';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../features/book/domain/book_balance.dart';
import '../../features/wallets/domain/wallet_balance.dart';
import '../errors/app_exception.dart';
import '../models/models.dart';
import '../repositories/book_repository.dart';
import 'app_database.dart';

/// SQLite implementation of [BookRepository] over the `book_*` tables.
///
/// Everything targets SQLite 3.9 (Android API 24): no window functions, no
/// row values, no UPSERT, no RETURNING.
final class SqliteBookRepository implements BookRepository {
  SqliteBookRepository(this._appDatabase, {void Function()? onChanged})
    : _onChanged = onChanged;

  final AppDatabase _appDatabase;
  final void Function()? _onChanged;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  Future<Database> get _db => _appDatabase.database;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<T> write<T>(Future<T> Function(BookWriter writer) action) async {
    final database = await _db;
    final result = await database.transaction(
      (transaction) => action(_SqliteWriter(transaction)),
    );
    if (!_changes.isClosed) {
      _changes.add(null);
    }
    _onChanged?.call();
    return result;
  }

  @override
  Future<BookCategory?> category(String id) async =>
      _categoryById(await _db, id);

  @override
  Future<List<CategorySummary>> categorySummaries({
    bool includeInactive = false,
    bool includeArchived = false,
  }) async {
    final database = await _db;
    final rows = await database.query(
      'book_categories',
      where:
          '(? = 1 OR is_active = 1) AND (? = 1 OR is_archived = 0)',
      whereArgs: <Object?>[includeInactive ? 1 : 0, includeArchived ? 1 : 0],
      orderBy: 'sort_order ASC, created_at ASC, name ASC',
    );
    final summaries = await _accountSummaries(
      database,
      where: "a.status != 'archived'",
    );
    final byCategory = <String, List<AccountSummary>>{};
    for (final summary in summaries) {
      byCategory
          .putIfAbsent(summary.account.categoryId, () => <AccountSummary>[])
          .add(summary);
    }
    return [
      for (final row in rows)
        () {
          final category = _category(row);
          final accounts = byCategory[category.id] ?? const <AccountSummary>[];
          return CategorySummary(
            category: category,
            accountCount: accounts.length,
            totals: BookBalanceEngine.currencyTotals(accounts),
          );
        }(),
    ];
  }

  @override
  Future<BookAccount?> account(String id) async =>
      _accountById(await _db, id);

  @override
  Future<AccountSummary?> accountSummary(String id) async {
    final rows = await _accountSummaries(
      await _db,
      where: 'a.id = ?',
      args: <Object?>[id],
    );
    return rows.isEmpty ? null : rows.single;
  }

  @override
  Future<List<AccountSummary>> accountSummaries({
    String? categoryId,
    bool includeArchived = true,
    bool activeCategoriesOnly = false,
  }) async => _accountSummaries(
    await _db,
    joinCategory: activeCategoriesOnly,
    where: [
      if (categoryId != null) 'a.category_id = ?',
      if (!includeArchived) "a.status != 'archived'",
      if (activeCategoriesOnly) 'c.is_active = 1 AND c.is_archived = 0',
    ].join(' AND '),
    args: <Object?>[?categoryId],
  );

  @override
  Future<int> accountCount(String categoryId) async =>
      Sqflite.firstIntValue(
        await (await _db).rawQuery(
          'SELECT COUNT(*) FROM book_accounts WHERE category_id = ?',
          <Object?>[categoryId],
        ),
      ) ??
      0;

  @override
  Future<TransactionPage> transactionPage(
    String accountId, {
    BookTransactionFilter filter = BookTransactionFilter.none,
    BookOrderKey? after,
    int limit = 50,
    bool newestFirst = true,
  }) async {
    final database = await _db;
    final args = <Object?>[accountId];
    final where = StringBuffer(
      't.account_id = ? AND t.deleted_at IS NULL',
    )..write(_filterSql(filter, args));
    if (after != null) {
      where.write(' AND ${_cursorSql(after, args, ascending: !newestFirst)}');
    }
    final direction = newestFirst ? 'DESC' : 'ASC';
    final rows = await database.rawQuery(
      'SELECT t.* FROM book_transactions t WHERE $where '
      'ORDER BY t.transaction_date $direction, t.transaction_time $direction, '
      't.created_at $direction, t.id $direction LIMIT ?',
      <Object?>[...args, limit + 1],
    );
    final pageRows = rows.take(limit).toList();
    final attachments = await _attachmentsFor(
      database,
      pageRows.map((row) => row['id']! as String),
    );
    return TransactionPage(
      items: List<BookTransaction>.unmodifiable([
        for (final row in pageRows)
          _transaction(row, attachments[row['id']] ?? const []),
      ]),
      hasMore: rows.length > limit,
    );
  }

  @override
  Future<List<AccountCurrencyTotals>> filteredTotals(
    String accountId, {
    BookTransactionFilter filter = BookTransactionFilter.none,
  }) async {
    final args = <Object?>[accountId];
    final where = 't.account_id = ? AND t.deleted_at IS NULL'
        '${_filterSql(filter, args)}';
    final rows = await (await _db).rawQuery(
      'SELECT t.currency_code AS currency_code, '
      "COALESCE(SUM(CASE t.type WHEN 'DEBIT' THEN t.amount_minor "
      "ELSE 0 END), 0) AS debit, "
      "COALESCE(SUM(CASE t.type WHEN 'CREDIT' THEN t.amount_minor "
      "ELSE 0 END), 0) AS credit, COUNT(*) AS count "
      'FROM book_transactions t WHERE $where '
      'GROUP BY t.currency_code ORDER BY t.currency_code ASC',
      args,
    );
    return List<AccountCurrencyTotals>.unmodifiable([
      for (final row in rows)
        AccountCurrencyTotals(
          currencyCode: row['currency_code']! as String,
          debitMinor: row['debit']! as int,
          creditMinor: row['credit']! as int,
          transactionCount: row['count']! as int,
        ),
    ]);
  }

  @override
  Future<List<BookAccountBalance>> accountBalancesOf(String accountId) async =>
      _accountBalancesOf(await _db, accountId);

  @override
  Future<List<BookTransaction>> reportTransactions({
    String? categoryId,
    String? accountId,
    String? currencyCode,
    String? toDate,
  }) async {
    final args = <Object?>[];
    final where = StringBuffer('t.deleted_at IS NULL');
    if (accountId != null) {
      where.write(' AND t.account_id = ?');
      args.add(accountId);
    }
    if (currencyCode != null) {
      where.write(' AND t.currency_code = ?');
      args.add(currencyCode.toUpperCase());
    }
    if (categoryId != null) {
      where.write(' AND a.category_id = ?');
      args.add(categoryId);
    }
    if (toDate != null) {
      where.write(' AND t.transaction_date <= ?');
      args.add(toDate);
    }
    final rows = await (await _db).rawQuery(
      'SELECT t.* FROM book_transactions t '
      'JOIN book_accounts a ON a.id = t.account_id '
      'WHERE $where '
      'ORDER BY t.transaction_date ASC, t.transaction_time ASC, '
      't.created_at ASC, t.id ASC',
      args,
    );
    return List<BookTransaction>.unmodifiable([
      for (final row in rows) _transaction(row, const []),
    ]);
  }

  @override
  Future<BookTransaction?> transaction(String id) async {
    final database = await _db;
    final row = await _transactionRow(database, id);
    if (row == null) return null;
    final attachments = await _attachmentsFor(database, [id]);
    return _transaction(row, attachments[id] ?? const []);
  }

  @override
  Future<List<BookTransaction>> recentTransactions({int limit = 10}) async {
    final database = await _db;
    final rows = await database.rawQuery(
      'SELECT t.* FROM book_transactions t '
      'JOIN book_accounts a ON a.id = t.account_id '
      'JOIN book_categories c ON c.id = a.category_id '
      'WHERE t.deleted_at IS NULL AND c.is_active = 1 AND c.is_archived = 0 '
      'ORDER BY t.transaction_date DESC, t.transaction_time DESC, '
      't.created_at DESC, t.id DESC LIMIT ?',
      <Object?>[limit],
    );
    final attachments = await _attachmentsFor(
      database,
      rows.map((row) => row['id']! as String),
    );
    return List<BookTransaction>.unmodifiable([
      for (final row in rows)
        _transaction(row, attachments[row['id']] ?? const []),
    ]);
  }

  @override
  Future<BookAuditPage> auditPage({
    String? accountId,
    BookAuditEntity? entity,
    BookAuditEntry? after,
    int limit = 50,
  }) async {
    final database = await _db;
    final where = StringBuffer('1 = 1');
    final args = <Object?>[];
    if (entity != null) {
      where.write(' AND l.entity_type = ?');
      args.add(entity.dbValue);
    }
    if (accountId != null) {
      where.write(' AND a.id = ?');
      args.add(accountId);
    }
    if (after != null) {
      where.write(
        ' AND (l.created_at < ? OR (l.created_at = ? AND l.rowid < ?))',
      );
      final at = after.createdAt.toUtc().millisecondsSinceEpoch;
      args.addAll(<Object?>[at, at, after.sequence]);
    }
    args.add(limit + 1);
    final rows = await database.rawQuery(
      'SELECT l.rowid AS seq, l.id, l.entity_type, l.entity_id, l.action, '
      'l.details, l.created_at, a.id AS account_id, a.name AS account_name, '
      't.currency_code AS currency_code, c.name AS category_name, '
      't.transaction_number AS tx_number '
      'FROM book_audit_log l '
      "LEFT JOIN book_transactions t ON l.entity_type = 'transaction' "
      'AND t.id = l.entity_id '
      'LEFT JOIN book_accounts a ON a.id = '
      "CASE l.entity_type WHEN 'transaction' THEN t.account_id "
      "WHEN 'account' THEN l.entity_id END "
      "LEFT JOIN book_categories c ON l.entity_type = 'category' "
      'AND c.id = l.entity_id '
      'WHERE $where '
      'ORDER BY l.created_at DESC, l.rowid DESC LIMIT ?',
      args,
    );
    final entries = <BookAuditEntry>[];
    for (final row in rows.take(limit)) {
      final kind = BookAuditEntity.fromDb(row['entity_type']! as String);
      // A row written by a future version for an unknown kind is skipped.
      if (kind == null) continue;
      entries.add(
        BookAuditEntry(
          id: row['id']! as String,
          sequence: row['seq']! as int,
          entity: kind,
          entityId: row['entity_id']! as String,
          action: row['action']! as String,
          details: row['details'] as String?,
          createdAt: _date(row['created_at']),
          accountId: row['account_id'] as String?,
          accountName: row['account_name'] as String?,
          currencyCode: row['currency_code'] as String?,
          categoryName: row['category_name'] as String?,
          transactionNumber: row['tx_number'] as String?,
        ),
      );
    }
    return BookAuditPage(
      items: List<BookAuditEntry>.unmodifiable(entries),
      hasMore: rows.length > limit,
    );
  }

  @override
  Future<List<CurrencyTotals>> netPosition() async {
    final summaries = await _accountSummaries(
      await _db,
      joinCategory: true,
      where: "a.status != 'archived' AND c.is_active = 1 AND c.is_archived = 0",
    );
    return BookBalanceEngine.currencyTotals(summaries);
  }

  @override
  Future<DocumentFile?> legacyDocumentFile(String documentFileId) async {
    final rows = await (await _db).query(
      'document_files',
      where: 'id = ?',
      whereArgs: <Object?>[documentFileId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return DocumentFile(
      id: row['id']! as String,
      documentId: row['document_id']! as String,
      encryptedFileName: row['encrypted_file_name']! as String,
      originalExtension: row['original_extension']! as String,
      mimeType: row['mime_type']! as String,
      encryptedSizeBytes: row['encrypted_size']! as int,
      checksum: row['checksum']! as String,
      createdAt: _date(row['created_at']),
    );
  }

  /// Tells watchers the data changed outside a write (after a restore).
  void refresh() {
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }

  @override
  Future<int> countBalanceMismatches(String accountId) async {
    final database = await _db;
    final account = await _accountById(database, accountId);
    if (account == null) return 0;
    final openings = {
      for (final balance in await _accountBalancesOf(database, accountId))
        balance.currencyCode: balance.openingSignedMinor,
    };
    final rows = await database.rawQuery(
      'SELECT * FROM book_transactions WHERE account_id = ? '
      'AND deleted_at IS NULL '
      'ORDER BY transaction_date ASC, transaction_time ASC, created_at ASC, '
      'id ASC',
      <Object?>[accountId],
    );
    // Each currency is checked against its own running balance.
    final byCurrency = <String, List<BookTransaction>>{};
    for (final row in rows) {
      final transaction = _transaction(row, const []);
      (byCurrency[transaction.currencyCode] ??= []).add(transaction);
    }
    var mismatches = 0;
    byCurrency.forEach((code, transactions) {
      final expected = BookBalanceEngine.recompute(
        openings[code] ?? 0,
        transactions,
      );
      for (var index = 0; index < transactions.length; index++) {
        if (transactions[index].balanceAfter != expected[index]) mismatches++;
      }
    });
    return mismatches;
  }

  @override
  Future<Wallet?> wallet(String id) async => _walletById(await _db, id);

  @override
  Future<WalletSummary?> walletSummary(String id) async {
    final rows = await _walletSummaries(
      await _db,
      where: 'w.id = ?',
      args: <Object?>[id],
    );
    return rows.isEmpty ? null : rows.single;
  }

  @override
  Future<List<WalletSummary>> walletSummaries({
    bool includeArchived = true,
  }) async => _walletSummaries(
    await _db,
    where: includeArchived ? '' : "w.status != 'archived'",
  );

  @override
  Future<List<WalletBalance>> walletBalancesOf(String walletId) async =>
      _walletBalancesOf(await _db, walletId);

  @override
  Future<int> countWalletBalanceMismatches(String walletId) async {
    final database = await _db;
    final wallet = await _walletById(database, walletId);
    if (wallet == null) return 0;
    final openings = {
      for (final balance in await _walletBalancesOf(database, walletId))
        balance.currencyCode: balance.openingMinor,
    };
    final rows = await database.rawQuery(
      'SELECT * FROM wallet_transactions WHERE wallet_id = ? '
      'AND deleted_at IS NULL '
      'ORDER BY transaction_date ASC, transaction_time ASC, created_at ASC, '
      'id ASC',
      <Object?>[walletId],
    );
    // Each currency is checked against its own running balance.
    final byCurrency = <String, List<WalletTransaction>>{};
    for (final row in rows) {
      final transaction = _walletTransaction(row);
      (byCurrency[transaction.currencyCode] ??= []).add(transaction);
    }
    var mismatches = 0;
    byCurrency.forEach((code, transactions) {
      final expected = WalletBalanceEngine.recompute(
        openings[code] ?? 0,
        transactions,
      );
      for (var index = 0; index < transactions.length; index++) {
        if (transactions[index].balanceAfter != expected[index]) mismatches++;
      }
    });
    return mismatches;
  }

  @override
  Future<List<WalletCurrencyTotal>> walletTotalsByCurrency() async {
    final summaries = await _walletSummaries(
      await _db,
      where: "w.status != 'archived'",
    );
    return WalletBalanceEngine.currencyTotals(summaries);
  }

  @override
  Future<WalletTransactionPage> walletTransactionPage(
    String walletId, {
    String? currencyCode,
    WalletTransactionFilter filter = WalletTransactionFilter.none,
    WalletOrderKey? after,
    int limit = 50,
    bool newestFirst = true,
  }) async {
    final database = await _db;
    final args = <Object?>[walletId];
    final where = StringBuffer(
      't.wallet_id = ? AND t.deleted_at IS NULL',
    );
    if (currencyCode != null) {
      where.write(' AND t.currency_code = ?');
      args.add(currencyCode);
    }
    where.write(_walletFilterSql(filter, args));
    if (after != null) {
      where.write(
        ' AND ${_walletCursorSql(after, args, ascending: !newestFirst)}',
      );
    }
    final direction = newestFirst ? 'DESC' : 'ASC';
    final rows = await database.rawQuery(
      'SELECT t.* FROM wallet_transactions t WHERE $where '
      'ORDER BY t.transaction_date $direction, t.transaction_time $direction, '
      't.created_at $direction, t.id $direction LIMIT ?',
      <Object?>[...args, limit + 1],
    );
    final pageRows = rows.take(limit).toList();
    return WalletTransactionPage(
      items: List<WalletTransaction>.unmodifiable([
        for (final row in pageRows) _walletTransaction(row),
      ]),
      hasMore: rows.length > limit,
    );
  }

  @override
  Future<WalletTransaction?> walletTransaction(String id) async {
    final rows = await (await _db).query(
      'wallet_transactions',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isEmpty ? null : _walletTransaction(rows.single);
  }

  @override
  Future<List<WalletTransaction>> walletReportTransactions(
    String walletId, {
    String? currencyCode,
    String? toDate,
  }) async {
    final args = <Object?>[walletId];
    final where = StringBuffer('wallet_id = ? AND deleted_at IS NULL');
    if (currencyCode != null) {
      where.write(' AND currency_code = ?');
      args.add(currencyCode);
    }
    if (toDate != null) {
      where.write(' AND transaction_date <= ?');
      args.add(toDate);
    }
    final rows = await (await _db).query(
      'wallet_transactions',
      where: where.toString(),
      whereArgs: args,
      orderBy:
          'transaction_date ASC, transaction_time ASC, created_at ASC, id ASC',
    );
    return List<WalletTransaction>.unmodifiable([
      for (final row in rows) _walletTransaction(row),
    ]);
  }

  @override
  Future<void> dispose() async {
    await _changes.close();
  }

  // ---- query helpers ------------------------------------------------------

  /// Two queries stitched together: the accounts in display order, then
  /// every (account, currency) bucket for them — its opening balance plus the
  /// live debits and credits in that currency. A single `GROUP BY a.id` would
  /// add different currencies together, which must never happen.
  Future<List<AccountSummary>> _accountSummaries(
    DatabaseExecutor executor, {
    String where = '',
    List<Object?> args = const <Object?>[],
    bool joinCategory = false,
  }) async {
    final from =
        'FROM book_accounts a '
        '${joinCategory ? 'JOIN book_categories c ON c.id = a.category_id ' : ''}'
        '${where.isEmpty ? '' : 'WHERE $where '}';
    final accountRows = await executor.rawQuery(
      'SELECT a.* $from'
      'ORDER BY a.name COLLATE NOCASE ASC, a.id ASC',
      args,
    );
    if (accountRows.isEmpty) return const [];
    final lineRows = await executor.rawQuery(
      'SELECT b.account_id AS account_id, b.currency_code AS currency_code, '
      'b.opening_minor AS opening_minor, b.opening_type AS opening_type, '
      "COALESCE(SUM(CASE WHEN t.type = 'DEBIT' THEN t.amount_minor END), 0) "
      'AS debit_sum, '
      "COALESCE(SUM(CASE WHEN t.type = 'CREDIT' THEN t.amount_minor END), 0) "
      'AS credit_sum, COUNT(t.id) AS tx_count '
      '${joinCategory ? 'FROM book_accounts a JOIN book_categories c ON c.id = a.category_id ' : 'FROM book_accounts a '}'
      'JOIN book_account_balances b ON b.account_id = a.id '
      'LEFT JOIN book_transactions t ON t.account_id = b.account_id '
      'AND t.currency_code = b.currency_code AND t.deleted_at IS NULL '
      '${where.isEmpty ? '' : 'WHERE $where '}'
      'GROUP BY b.account_id, b.currency_code '
      'ORDER BY b.account_id ASC, b.currency_code ASC',
      args,
    );
    final linesByAccount = <String, List<AccountCurrencyTotals>>{};
    for (final row in lineRows) {
      final opening = row['opening_minor']! as int;
      final type = OpeningType.fromDb(row['opening_type']! as String);
      final line = AccountCurrencyTotals(
        currencyCode: row['currency_code']! as String,
        openingMinor: opening,
        openingType: type,
        debitMinor:
            (row['debit_sum']! as int) +
            (type == OpeningType.debit ? opening : 0),
        creditMinor:
            (row['credit_sum']! as int) +
            (type == OpeningType.credit ? opening : 0),
        transactionCount: row['tx_count']! as int,
      );
      // Only the currencies the account uses: an opening balance or at least
      // one live transaction.
      if (line.isUsed) {
        (linesByAccount[row['account_id']! as String] ??= []).add(line);
      }
    }
    return [
      for (final row in accountRows)
        AccountSummary(
          account: _account(row),
          currencies: List<AccountCurrencyTotals>.unmodifiable(
            linesByAccount[row['id']! as String] ?? const [],
          ),
        ),
    ];
  }

  static Future<List<BookAccountBalance>> _accountBalancesOf(
    DatabaseExecutor executor,
    String accountId,
  ) async {
    final rows = await executor.query(
      'book_account_balances',
      where: 'account_id = ?',
      whereArgs: <Object?>[accountId],
      orderBy: 'currency_code ASC',
    );
    return List<BookAccountBalance>.unmodifiable([
      for (final row in rows) _accountBalance(row),
    ]);
  }

  /// SQL for [filter] (starting with ` AND`), appending its arguments.
  static String _filterSql(BookTransactionFilter filter, List<Object?> args) {
    final sql = StringBuffer();
    if (filter.type != null) {
      sql.write(' AND t.type = ?');
      args.add(filter.type!.dbValue);
    }
    if (filter.currencyCode != null) {
      sql.write(' AND t.currency_code = ?');
      args.add(filter.currencyCode!.toUpperCase());
    }
    if (filter.fromDate != null) {
      sql.write(' AND t.transaction_date >= ?');
      args.add(filter.fromDate);
    }
    if (filter.toDate != null) {
      sql.write(' AND t.transaction_date <= ?');
      args.add(filter.toDate);
    }
    if (filter.minAmountMinor != null) {
      sql.write(' AND t.amount_minor >= ?');
      args.add(filter.minAmountMinor);
    }
    if (filter.maxAmountMinor != null) {
      sql.write(' AND t.amount_minor <= ?');
      args.add(filter.maxAmountMinor);
    }
    if (filter.withAttachments) {
      sql.write(
        ' AND EXISTS (SELECT 1 FROM book_attachments x '
        'WHERE x.transaction_id = t.id)',
      );
    }
    if (filter.walletId != null) {
      sql.write(' AND t.wallet_id = ?');
      args.add(filter.walletId);
    }
    final text = filter.text?.trim();
    if (text != null && text.isNotEmpty) {
      final pattern = '%${escapeLike(text)}%';
      final amounts = filter.textAmountsMinor?.entries.toList() ?? const [];
      sql.write(
        " AND (t.details LIKE ? ESCAPE '\\' OR t.notes LIKE ? ESCAPE '\\' "
        "OR t.transaction_number LIKE ? ESCAPE '\\' "
        "OR t.transaction_date LIKE ? ESCAPE '\\' "
        "OR CAST(t.amount_minor AS TEXT) LIKE ? ESCAPE '\\'"
        '${amounts.isEmpty ? '' : ' OR (t.currency_code = ? AND t.amount_minor = ?)' * amounts.length})',
      );
      args.addAll(<Object?>[pattern, pattern, pattern, pattern, pattern]);
      for (final entry in amounts) {
        args.addAll(<Object?>[entry.key.toUpperCase(), entry.value]);
      }
    }
    return sql.toString();
  }

  /// Keyset condition for rows strictly after [key] in the chosen direction.
  static String _cursorSql(
    BookOrderKey key,
    List<Object?> args, {
    required bool ascending,
  }) {
    final op = ascending ? '>' : '<';
    args.addAll(<Object?>[
      key.date,
      key.date,
      key.time,
      key.date,
      key.time,
      key.createdAtMs,
      key.date,
      key.time,
      key.createdAtMs,
      key.id,
    ]);
    return '(t.transaction_date $op ? '
        'OR (t.transaction_date = ? AND t.transaction_time $op ?) '
        'OR (t.transaction_date = ? AND t.transaction_time = ? '
        'AND t.created_at $op ?) '
        'OR (t.transaction_date = ? AND t.transaction_time = ? '
        'AND t.created_at = ? AND t.id $op ?))';
  }

  /// Two queries stitched together: the wallets in display order, then every
  /// (wallet, currency) balance bucket for them. A single `GROUP BY w.id`
  /// cannot express a wallet holding several currencies at once.
  Future<List<WalletSummary>> _walletSummaries(
    DatabaseExecutor executor, {
    String where = '',
    List<Object?> args = const <Object?>[],
  }) async {
    final walletRows = await executor.rawQuery(
      'SELECT w.* FROM wallets w '
      '${where.isEmpty ? '' : 'WHERE $where '}'
      'ORDER BY w.is_main DESC, w.sort_order ASC, '
      'w.name COLLATE NOCASE ASC, w.id ASC',
      args,
    );
    if (walletRows.isEmpty) return const [];
    final wallets = [for (final row in walletRows) _wallet(row)];
    final placeholders = List.filled(wallets.length, '?').join(', ');
    final balanceRows = await executor.rawQuery(
      'SELECT b.wallet_id, b.currency_code, b.opening_minor, b.sort_order, '
      "COALESCE(SUM(CASE t.direction WHEN 'IN' THEN t.amount_minor "
      'ELSE -t.amount_minor END), 0) AS movement_sum, '
      'COUNT(t.id) AS tx_count '
      'FROM wallet_balances b '
      'LEFT JOIN wallet_transactions t '
      'ON t.wallet_id = b.wallet_id AND t.currency_code = b.currency_code '
      'AND t.deleted_at IS NULL '
      'WHERE b.wallet_id IN ($placeholders) '
      'GROUP BY b.wallet_id, b.currency_code '
      'ORDER BY b.sort_order ASC, b.currency_code ASC',
      [for (final wallet in wallets) wallet.id],
    );
    final balancesByWallet = <String, List<WalletCurrencyBalance>>{};
    final countsByWallet = <String, int>{};
    for (final row in balanceRows) {
      final walletId = row['wallet_id']! as String;
      final opening = row['opening_minor']! as int;
      final movementSum = row['movement_sum']! as int;
      final txCount = row['tx_count']! as int;
      (balancesByWallet[walletId] ??= []).add(
        WalletCurrencyBalance(
          currencyCode: row['currency_code']! as String,
          openingMinor: opening,
          balanceMinor: opening + movementSum,
          transactionCount: txCount,
        ),
      );
      countsByWallet[walletId] = (countsByWallet[walletId] ?? 0) + txCount;
    }
    return [
      for (final wallet in wallets)
        WalletSummary(
          wallet: wallet,
          balances: balancesByWallet[wallet.id] ?? const [],
          transactionCount: countsByWallet[wallet.id] ?? 0,
        ),
    ];
  }

  static Future<List<WalletBalance>> _walletBalancesOf(
    DatabaseExecutor executor,
    String walletId,
  ) async {
    final rows = await executor.query(
      'wallet_balances',
      where: 'wallet_id = ?',
      whereArgs: <Object?>[walletId],
      orderBy: 'sort_order ASC, currency_code ASC',
    );
    return List<WalletBalance>.unmodifiable([
      for (final row in rows) _walletBalance(row),
    ]);
  }

  /// SQL for [filter] (starting with ` AND`), appending its arguments.
  static String _walletFilterSql(
    WalletTransactionFilter filter,
    List<Object?> args,
  ) {
    final sql = StringBuffer();
    if (filter.type != null) {
      sql.write(' AND t.type = ?');
      args.add(filter.type!.dbValue);
    }
    if (filter.fromDate != null) {
      sql.write(' AND t.transaction_date >= ?');
      args.add(filter.fromDate);
    }
    if (filter.toDate != null) {
      sql.write(' AND t.transaction_date <= ?');
      args.add(filter.toDate);
    }
    return sql.toString();
  }

  /// Keyset condition for rows strictly after [key] in the chosen direction.
  static String _walletCursorSql(
    WalletOrderKey key,
    List<Object?> args, {
    required bool ascending,
  }) {
    final op = ascending ? '>' : '<';
    args.addAll(<Object?>[
      key.date,
      key.date,
      key.time,
      key.date,
      key.time,
      key.createdAtMs,
      key.date,
      key.time,
      key.createdAtMs,
      key.id,
    ]);
    return '(t.transaction_date $op ? '
        'OR (t.transaction_date = ? AND t.transaction_time $op ?) '
        'OR (t.transaction_date = ? AND t.transaction_time = ? '
        'AND t.created_at $op ?) '
        'OR (t.transaction_date = ? AND t.transaction_time = ? '
        'AND t.created_at = ? AND t.id $op ?))';
  }

  static Future<Wallet?> _walletById(
    DatabaseExecutor executor,
    String id,
  ) async {
    final rows = await executor.query(
      'wallets',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isEmpty ? null : _wallet(rows.single);
  }

  static Future<Map<String, List<BookAttachment>>> _attachmentsFor(
    DatabaseExecutor executor,
    Iterable<String> transactionIds,
  ) async {
    final ids = transactionIds.toList();
    final result = <String, List<BookAttachment>>{};
    if (ids.isEmpty) return result;
    final rows = await executor.rawQuery(
      'SELECT * FROM book_attachments WHERE transaction_id IN '
      '(${List.filled(ids.length, '?').join(',')}) '
      'ORDER BY created_at ASC, id ASC',
      ids,
    );
    for (final row in rows) {
      result
          .putIfAbsent(row['transaction_id']! as String, () => [])
          .add(_attachment(row));
    }
    return result;
  }

  static Future<BookCategory?> _categoryById(
    DatabaseExecutor executor,
    String id,
  ) async {
    final rows = await executor.query(
      'book_categories',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isEmpty ? null : _category(rows.single);
  }

  static Future<BookAccount?> _accountById(
    DatabaseExecutor executor,
    String id,
  ) async {
    final rows = await executor.query(
      'book_accounts',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isEmpty ? null : _account(rows.single);
  }

  static Future<Map<String, Object?>?> _transactionRow(
    DatabaseExecutor executor,
    String id,
  ) async {
    final rows = await executor.query(
      'book_transactions',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single;
  }

  // ---- row mapping --------------------------------------------------------

  static DateTime _date(Object? value) =>
      DateTime.fromMillisecondsSinceEpoch(value! as int, isUtc: true);

  static int _ms(DateTime value) => value.toUtc().millisecondsSinceEpoch;

  static BookCategory _category(Map<String, Object?> row) => BookCategory(
    id: row['id']! as String,
    name: row['name']! as String,
    icon: row['icon'] as String?,
    description: row['description'] as String?,
    sortOrder: row['sort_order']! as int,
    isActive: row['is_active'] == 1,
    isArchived: row['is_archived'] == 1,
    createdAt: _date(row['created_at']),
    updatedAt: _date(row['updated_at']),
  );

  static Map<String, Object?> _categoryValues(BookCategory category) =>
      <String, Object?>{
        'id': category.id,
        'name': category.name,
        'icon': category.icon,
        'description': category.description,
        'sort_order': category.sortOrder,
        'is_active': category.isActive ? 1 : 0,
        'is_archived': category.isArchived ? 1 : 0,
        'created_at': _ms(category.createdAt),
        'updated_at': _ms(category.updatedAt),
      };

  static BookAccount _account(Map<String, Object?> row) => BookAccount(
    id: row['id']! as String,
    categoryId: row['category_id']! as String,
    name: row['name']! as String,
    notes: row['notes'] as String?,
    phone: row['phone'] as String?,
    status: BookAccountStatus.fromDb(row['status']! as String),
    sortOrder: row['sort_order']! as int,
    legacyAccountId: row['legacy_account_id'] as String?,
    createdAt: _date(row['created_at']),
    updatedAt: _date(row['updated_at']),
  );

  static Map<String, Object?> _accountValues(BookAccount account) =>
      <String, Object?>{
        'id': account.id,
        'category_id': account.categoryId,
        'name': account.name,
        'notes': account.notes,
        'phone': account.phone,
        'status': account.status.dbValue,
        'sort_order': account.sortOrder,
        'legacy_account_id': account.legacyAccountId,
        'created_at': _ms(account.createdAt),
        'updated_at': _ms(account.updatedAt),
      };

  static BookAccountBalance _accountBalance(Map<String, Object?> row) =>
      BookAccountBalance(
        accountId: row['account_id']! as String,
        currencyCode: row['currency_code']! as String,
        openingMinor: row['opening_minor']! as int,
        openingType: OpeningType.fromDb(row['opening_type']! as String),
        createdAt: _date(row['created_at']),
        updatedAt: _date(row['updated_at']),
      );

  static Map<String, Object?> _accountBalanceValues(
    BookAccountBalance balance,
  ) => <String, Object?>{
    'account_id': balance.accountId,
    'currency_code': balance.currencyCode,
    'opening_minor': balance.openingMinor,
    'opening_type': balance.openingType.dbValue,
    'created_at': _ms(balance.createdAt),
    'updated_at': _ms(balance.updatedAt),
  };

  static BookTransaction _transaction(
    Map<String, Object?> row,
    List<BookAttachment> attachments,
  ) => BookTransaction(
    id: row['id']! as String,
    number: row['transaction_number']! as String,
    accountId: row['account_id']! as String,
    currencyCode: row['currency_code']! as String,
    type: EntryType.fromDb(row['type']! as String),
    amountMinor: row['amount_minor']! as int,
    date: row['transaction_date']! as String,
    time: row['transaction_time']! as String,
    details: row['details'] as String?,
    notes: row['notes'] as String?,
    balanceAfter: row['balance_after']! as int,
    createdAt: _date(row['created_at']),
    updatedAt: _date(row['updated_at']),
    deletedAt: row['deleted_at'] == null ? null : _date(row['deleted_at']),
    attachments: attachments,
    walletId: row['wallet_id'] as String?,
    walletEffect: row['wallet_effect'] == null
        ? null
        : WalletBalanceEffect.fromDb(row['wallet_effect']! as String),
  );

  static Map<String, Object?> _transactionValues(BookTransaction row) =>
      <String, Object?>{
        'id': row.id,
        'transaction_number': row.number,
        'account_id': row.accountId,
        'currency_code': row.currencyCode,
        'type': row.type.dbValue,
        'amount_minor': row.amountMinor,
        'transaction_date': row.date,
        'transaction_time': row.time,
        'details': row.details,
        'notes': row.notes,
        'balance_after': row.balanceAfter,
        'created_at': _ms(row.createdAt),
        'updated_at': _ms(row.updatedAt),
        'deleted_at': row.deletedAt == null ? null : _ms(row.deletedAt!),
        'wallet_id': row.walletId,
        'wallet_effect': row.walletEffect?.dbValue,
      };

  static BookAttachment _attachment(Map<String, Object?> row) => BookAttachment(
    id: row['id']! as String,
    transactionId: row['transaction_id']! as String,
    kind: BookAttachmentKind.fromDb(row['kind']! as String),
    fileName: row['file_name']! as String,
    mimeType: row['mime_type']! as String,
    encryptedFileName: row['encrypted_file_name'] as String?,
    originalExtension: row['original_extension'] as String?,
    fileSize: row['file_size']! as int,
    checksum: row['checksum'] as String?,
    documentFileId: row['document_file_id'] as String?,
    createdAt: _date(row['created_at']),
  );

  static Map<String, Object?> _attachmentValues(BookAttachment item) =>
      <String, Object?>{
        'id': item.id,
        'transaction_id': item.transactionId,
        'kind': item.kind.dbValue,
        'file_name': item.fileName,
        'mime_type': item.mimeType,
        'encrypted_file_name': item.encryptedFileName,
        'original_extension': item.originalExtension,
        'file_size': item.fileSize,
        'checksum': item.checksum,
        'document_file_id': item.documentFileId,
        'created_at': _ms(item.createdAt),
      };

  static Wallet _wallet(Map<String, Object?> row) => Wallet(
    id: row['id']! as String,
    name: row['name']! as String,
    isMain: row['is_main'] == 1,
    accountNumber: row['account_number'] as String?,
    image: row['image'] as Uint8List?,
    notes: row['notes'] as String?,
    status: WalletStatus.fromDb(row['status']! as String),
    sortOrder: row['sort_order']! as int,
    createdAt: _date(row['created_at']),
    updatedAt: _date(row['updated_at']),
  );

  static Map<String, Object?> _walletValues(Wallet wallet) => <String, Object?>{
    'id': wallet.id,
    'name': wallet.name,
    'is_main': wallet.isMain ? 1 : 0,
    'account_number': wallet.accountNumber,
    'image': wallet.image,
    'notes': wallet.notes,
    'status': wallet.status.dbValue,
    'sort_order': wallet.sortOrder,
    'created_at': _ms(wallet.createdAt),
    'updated_at': _ms(wallet.updatedAt),
  };

  static WalletBalance _walletBalance(Map<String, Object?> row) =>
      WalletBalance(
        walletId: row['wallet_id']! as String,
        currencyCode: row['currency_code']! as String,
        openingMinor: row['opening_minor']! as int,
        sortOrder: row['sort_order']! as int,
        createdAt: _date(row['created_at']),
        updatedAt: _date(row['updated_at']),
      );

  static Map<String, Object?> _walletBalanceValues(WalletBalance balance) =>
      <String, Object?>{
        'wallet_id': balance.walletId,
        'currency_code': balance.currencyCode,
        'opening_minor': balance.openingMinor,
        'sort_order': balance.sortOrder,
        'created_at': _ms(balance.createdAt),
        'updated_at': _ms(balance.updatedAt),
      };

  static WalletTransaction _walletTransaction(Map<String, Object?> row) =>
      WalletTransaction(
        id: row['id']! as String,
        number: row['transaction_number']! as String,
        walletId: row['wallet_id']! as String,
        currencyCode: row['currency_code']! as String,
        type: WalletTransactionType.fromDb(row['type']! as String),
        direction: WalletDirection.fromDb(row['direction']! as String),
        amountMinor: row['amount_minor']! as int,
        balanceAfter: row['balance_after']! as int,
        legGroupId: row['leg_group_id'] as String?,
        linkedBookTransactionId: row['linked_book_transaction_id'] as String?,
        date: row['transaction_date']! as String,
        time: row['transaction_time']! as String,
        notes: row['notes'] as String?,
        createdAt: _date(row['created_at']),
        updatedAt: _date(row['updated_at']),
        deletedAt: row['deleted_at'] == null ? null : _date(row['deleted_at']),
      );

  static Map<String, Object?> _walletTransactionValues(
    WalletTransaction row,
  ) => <String, Object?>{
    'id': row.id,
    'transaction_number': row.number,
    'wallet_id': row.walletId,
    'currency_code': row.currencyCode,
    'type': row.type.dbValue,
    'direction': row.direction.dbValue,
    'amount_minor': row.amountMinor,
    'balance_after': row.balanceAfter,
    'leg_group_id': row.legGroupId,
    'linked_book_transaction_id': row.linkedBookTransactionId,
    'transaction_date': row.date,
    'transaction_time': row.time,
    'notes': row.notes,
    'created_at': _ms(row.createdAt),
    'updated_at': _ms(row.updatedAt),
    'deleted_at': row.deletedAt == null ? null : _ms(row.deletedAt!),
  };
}

/// Escapes `%`, `_` and `\` for a `LIKE ... ESCAPE '\'` pattern.
String escapeLike(String value) => value
    .replaceAll(r'\', r'\\')
    .replaceAll('%', r'\%')
    .replaceAll('_', r'\_');

final class _SqliteWriter implements BookWriter {
  _SqliteWriter(this._txn);

  final Transaction _txn;
  static const _uuid = Uuid();

  @override
  Future<BookCategory?> category(String id) =>
      SqliteBookRepository._categoryById(_txn, id);

  @override
  Future<BookAccount?> account(String id) =>
      SqliteBookRepository._accountById(_txn, id);

  @override
  Future<BookTransaction?> transaction(String id) async {
    final row = await SqliteBookRepository._transactionRow(_txn, id);
    return row == null ? null : SqliteBookRepository._transaction(row, const []);
  }

  @override
  Future<List<BookTransaction>> accountTransactions(
    String accountId, {
    required String currencyCode,
    BookOrderKey? from,
  }) async {
    final args = <Object?>[accountId, currencyCode.toUpperCase()];
    final where = StringBuffer(
      'account_id = ? AND currency_code = ? AND deleted_at IS NULL',
    );
    if (from != null) {
      args.addAll(<Object?>[
        from.date,
        from.date,
        from.time,
        from.date,
        from.time,
        from.createdAtMs,
        from.date,
        from.time,
        from.createdAtMs,
        from.id,
      ]);
      where.write(
        ' AND (transaction_date > ? '
        'OR (transaction_date = ? AND transaction_time > ?) '
        'OR (transaction_date = ? AND transaction_time = ? AND created_at > ?) '
        'OR (transaction_date = ? AND transaction_time = ? '
        'AND created_at = ? AND id >= ?))',
      );
    }
    final rows = await _txn.query(
      'book_transactions',
      where: where.toString(),
      whereArgs: args,
      orderBy:
          'transaction_date ASC, transaction_time ASC, created_at ASC, id ASC',
    );
    return [
      for (final row in rows) SqliteBookRepository._transaction(row, const []),
    ];
  }

  @override
  Future<BookTransaction?> previousTransaction(
    String accountId,
    String currencyCode,
    BookOrderKey key,
  ) async {
    final rows = await _txn.query(
      'book_transactions',
      where:
          'account_id = ? AND currency_code = ? AND deleted_at IS NULL AND '
          '(transaction_date < ? '
          'OR (transaction_date = ? AND transaction_time < ?) '
          'OR (transaction_date = ? AND transaction_time = ? AND created_at < ?) '
          'OR (transaction_date = ? AND transaction_time = ? '
          'AND created_at = ? AND id < ?))',
      whereArgs: <Object?>[
        accountId,
        currencyCode.toUpperCase(),
        key.date,
        key.date,
        key.time,
        key.date,
        key.time,
        key.createdAtMs,
        key.date,
        key.time,
        key.createdAtMs,
        key.id,
      ],
      orderBy:
          'transaction_date DESC, transaction_time DESC, created_at DESC, '
          'id DESC',
      limit: 1,
    );
    return rows.isEmpty
        ? null
        : SqliteBookRepository._transaction(rows.single, const []);
  }

  @override
  Future<List<BookAccountBalance>> accountBalances(String accountId) =>
      SqliteBookRepository._accountBalancesOf(_txn, accountId);

  @override
  Future<BookAccountBalance?> accountBalance(
    String accountId,
    String currencyCode,
  ) async {
    final rows = await _txn.query(
      'book_account_balances',
      where: 'account_id = ? AND currency_code = ?',
      whereArgs: <Object?>[accountId, currencyCode.toUpperCase()],
      limit: 1,
    );
    return rows.isEmpty
        ? null
        : SqliteBookRepository._accountBalance(rows.single);
  }

  @override
  Future<void> putAccountBalance(BookAccountBalance balance) => _upsertWhere(
    'book_account_balances',
    SqliteBookRepository._accountBalanceValues(balance),
    where: 'account_id = ? AND currency_code = ?',
    whereArgs: <Object?>[balance.accountId, balance.currencyCode],
  );

  @override
  Future<void> deleteAccountBalance(
    String accountId,
    String currencyCode,
  ) async {
    await _txn.delete(
      'book_account_balances',
      where: 'account_id = ? AND currency_code = ?',
      whereArgs: <Object?>[accountId, currencyCode.toUpperCase()],
    );
  }

  @override
  Future<int> categoryAccountCount(String categoryId) async =>
      Sqflite.firstIntValue(
        await _txn.rawQuery(
          'SELECT COUNT(*) FROM book_accounts WHERE category_id = ?',
          <Object?>[categoryId],
        ),
      ) ??
      0;

  @override
  Future<int> accountTransactionCount(
    String accountId, {
    String? currencyCode,
  }) async =>
      Sqflite.firstIntValue(
        await _txn.rawQuery(
          'SELECT COUNT(*) FROM book_transactions WHERE account_id = ?'
          '${currencyCode == null ? '' : ' AND currency_code = ?'}',
          <Object?>[accountId, ?currencyCode?.toUpperCase()],
        ),
      ) ??
      0;

  @override
  Future<List<BookAccount>> accountsOfCategory(String categoryId) async {
    final rows = await _txn.query(
      'book_accounts',
      where: 'category_id = ?',
      whereArgs: <Object?>[categoryId],
    );
    return [for (final row in rows) SqliteBookRepository._account(row)];
  }

  @override
  Future<List<BookTransaction>> allTransactionsOfAccount(
    String accountId,
  ) async {
    final rows = await _txn.query(
      'book_transactions',
      where: 'account_id = ?',
      whereArgs: <Object?>[accountId],
    );
    return [
      for (final row in rows) SqliteBookRepository._transaction(row, const []),
    ];
  }

  @override
  Future<List<BookAttachment>> attachments(String transactionId) async {
    final rows = await _txn.query(
      'book_attachments',
      where: 'transaction_id = ?',
      whereArgs: <Object?>[transactionId],
      orderBy: 'created_at ASC, id ASC',
    );
    return [for (final row in rows) SqliteBookRepository._attachment(row)];
  }

  @override
  Future<BookAttachment?> attachment(String id) async {
    final rows = await _txn.query(
      'book_attachments',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isEmpty ? null : SqliteBookRepository._attachment(rows.single);
  }

  @override
  Future<void> putCategory(BookCategory category) => _upsert(
    'book_categories',
    SqliteBookRepository._categoryValues(category),
  );

  @override
  Future<void> putAccount(BookAccount account) => _upsert(
    'book_accounts',
    SqliteBookRepository._accountValues(account),
  );

  @override
  Future<void> putTransaction(BookTransaction transaction) => _upsert(
    'book_transactions',
    SqliteBookRepository._transactionValues(transaction),
  );

  @override
  Future<void> putAttachment(BookAttachment attachment) => _upsert(
    'book_attachments',
    SqliteBookRepository._attachmentValues(attachment),
  );

  @override
  Future<void> updateBalances(Map<String, int> balanceAfterByTransactionId) async {
    final batch = _txn.batch();
    balanceAfterByTransactionId.forEach((id, balance) {
      batch.update(
        'book_transactions',
        <String, Object?>{'balance_after': balance},
        where: 'id = ?',
        whereArgs: <Object?>[id],
      );
    });
    await batch.commit(noResult: true);
  }

  @override
  Future<void> removeAttachment(String id) async {
    await _txn.delete(
      'book_attachments',
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  @override
  Future<void> deleteCategory(String id) async {
    await _txn.delete(
      'book_categories',
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  @override
  Future<void> deleteAccount(String id) async {
    await _txn.delete(
      'book_accounts',
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  @override
  Future<void> deleteTransactionHard(String id) async {
    await _txn.delete(
      'book_transactions',
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  @override
  Future<String> nextTransactionNumber() async {
    // SQLite 3.9 has neither UPSERT nor RETURNING.
    final updated = await _txn.rawUpdate(
      'UPDATE book_counters SET value = value + 1 WHERE name = ?',
      <Object?>['tx_number'],
    );
    if (updated == 0) {
      await _txn.insert('book_counters', <String, Object?>{
        'name': 'tx_number',
        'value': 1,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    final value = Sqflite.firstIntValue(
      await _txn.rawQuery(
        'SELECT value FROM book_counters WHERE name = ?',
        <Object?>['tx_number'],
      ),
    );
    if (value == null) {
      throw const StorageException(
        code: 'transaction_counter_missing',
        userMessage: 'تعذر إنشاء رقم للعملية.',
      );
    }
    return 'TX-${value.toString().padLeft(6, '0')}';
  }

  @override
  Future<Wallet?> wallet(String id) =>
      SqliteBookRepository._walletById(_txn, id);

  @override
  Future<Wallet?> mainWallet() async {
    final rows = await _txn.query(
      'wallets',
      where: 'is_main = 1',
      limit: 1,
    );
    return rows.isEmpty ? null : SqliteBookRepository._wallet(rows.single);
  }

  @override
  Future<List<WalletBalance>> walletBalances(String walletId) =>
      SqliteBookRepository._walletBalancesOf(_txn, walletId);

  @override
  Future<WalletBalance?> walletBalance(
    String walletId,
    String currencyCode,
  ) async {
    final rows = await _txn.query(
      'wallet_balances',
      where: 'wallet_id = ? AND currency_code = ?',
      whereArgs: <Object?>[walletId, currencyCode.toUpperCase()],
      limit: 1,
    );
    return rows.isEmpty
        ? null
        : SqliteBookRepository._walletBalance(rows.single);
  }

  @override
  Future<void> putWalletBalance(WalletBalance balance) => _upsertWhere(
    'wallet_balances',
    SqliteBookRepository._walletBalanceValues(balance),
    where: 'wallet_id = ? AND currency_code = ?',
    whereArgs: <Object?>[balance.walletId, balance.currencyCode],
  );

  @override
  Future<void> deleteWalletBalance(
    String walletId,
    String currencyCode,
  ) async {
    await _txn.delete(
      'wallet_balances',
      where: 'wallet_id = ? AND currency_code = ?',
      whereArgs: <Object?>[walletId, currencyCode.toUpperCase()],
    );
  }

  @override
  Future<void> deleteWalletBalances(String walletId) async {
    await _txn.delete(
      'wallet_balances',
      where: 'wallet_id = ?',
      whereArgs: <Object?>[walletId],
    );
  }

  @override
  Future<WalletTransaction?> walletTransaction(String id) async {
    final rows = await _txn.query(
      'wallet_transactions',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isEmpty
        ? null
        : SqliteBookRepository._walletTransaction(rows.single);
  }

  @override
  Future<List<WalletTransaction>> walletTransactionsOf(
    String walletId, {
    required String currencyCode,
    WalletOrderKey? from,
  }) async {
    // currency_code first: it, then wallet_id, are the leading columns of
    // idx_wtx_wallet_currency_date.
    final args = <Object?>[currencyCode.toUpperCase(), walletId];
    final where = StringBuffer(
      'currency_code = ? AND wallet_id = ? AND deleted_at IS NULL',
    );
    if (from != null) {
      args.addAll(<Object?>[
        from.date,
        from.date,
        from.time,
        from.date,
        from.time,
        from.createdAtMs,
        from.date,
        from.time,
        from.createdAtMs,
        from.id,
      ]);
      where.write(
        ' AND (transaction_date > ? '
        'OR (transaction_date = ? AND transaction_time > ?) '
        'OR (transaction_date = ? AND transaction_time = ? AND created_at > ?) '
        'OR (transaction_date = ? AND transaction_time = ? '
        'AND created_at = ? AND id >= ?))',
      );
    }
    final rows = await _txn.query(
      'wallet_transactions',
      where: where.toString(),
      whereArgs: args,
      orderBy:
          'transaction_date ASC, transaction_time ASC, created_at ASC, id ASC',
    );
    return [
      for (final row in rows) SqliteBookRepository._walletTransaction(row),
    ];
  }

  @override
  Future<WalletTransaction?> previousWalletTransaction(
    String walletId,
    String currencyCode,
    WalletOrderKey key,
  ) async {
    final rows = await _txn.query(
      'wallet_transactions',
      where:
          'currency_code = ? AND wallet_id = ? AND deleted_at IS NULL AND '
          '(transaction_date < ? '
          'OR (transaction_date = ? AND transaction_time < ?) '
          'OR (transaction_date = ? AND transaction_time = ? AND created_at < ?) '
          'OR (transaction_date = ? AND transaction_time = ? '
          'AND created_at = ? AND id < ?))',
      whereArgs: <Object?>[
        currencyCode.toUpperCase(),
        walletId,
        key.date,
        key.date,
        key.time,
        key.date,
        key.time,
        key.createdAtMs,
        key.date,
        key.time,
        key.createdAtMs,
        key.id,
      ],
      orderBy:
          'transaction_date DESC, transaction_time DESC, created_at DESC, '
          'id DESC',
      limit: 1,
    );
    return rows.isEmpty
        ? null
        : SqliteBookRepository._walletTransaction(rows.single);
  }

  @override
  Future<List<WalletTransaction>> allWalletTransactionsOf(
    String walletId,
  ) async {
    final rows = await _txn.query(
      'wallet_transactions',
      where: 'wallet_id = ?',
      whereArgs: <Object?>[walletId],
    );
    return [
      for (final row in rows) SqliteBookRepository._walletTransaction(row),
    ];
  }

  @override
  Future<List<WalletTransaction>> walletTransactionsInLegGroup(
    String legGroupId,
  ) async {
    final rows = await _txn.query(
      'wallet_transactions',
      where: 'leg_group_id = ?',
      whereArgs: <Object?>[legGroupId],
    );
    return [
      for (final row in rows) SqliteBookRepository._walletTransaction(row),
    ];
  }

  @override
  Future<WalletTransaction?> walletTransactionForBookTransaction(
    String bookTransactionId,
  ) async {
    final rows = await _txn.query(
      'wallet_transactions',
      where: 'linked_book_transaction_id = ?',
      whereArgs: <Object?>[bookTransactionId],
      limit: 1,
    );
    return rows.isEmpty
        ? null
        : SqliteBookRepository._walletTransaction(rows.single);
  }

  @override
  Future<int> walletTransactionCount(
    String walletId, {
    String? currencyCode,
  }) async {
    final args = <Object?>[walletId];
    final where = StringBuffer('wallet_id = ?');
    if (currencyCode != null) {
      where.write(' AND currency_code = ?');
      args.add(currencyCode.toUpperCase());
    }
    return Sqflite.firstIntValue(
          await _txn.rawQuery(
            'SELECT COUNT(*) FROM wallet_transactions WHERE $where',
            args,
          ),
        ) ??
        0;
  }

  @override
  Future<void> putWallet(Wallet wallet) =>
      _upsert('wallets', SqliteBookRepository._walletValues(wallet));

  @override
  Future<void> putWalletTransaction(WalletTransaction transaction) => _upsert(
    'wallet_transactions',
    SqliteBookRepository._walletTransactionValues(transaction),
  );

  @override
  Future<void> updateWalletBalances(
    Map<String, int> balanceAfterByWalletTransactionId,
  ) async {
    final batch = _txn.batch();
    balanceAfterByWalletTransactionId.forEach((id, balance) {
      batch.update(
        'wallet_transactions',
        <String, Object?>{'balance_after': balance},
        where: 'id = ?',
        whereArgs: <Object?>[id],
      );
    });
    await batch.commit(noResult: true);
  }

  @override
  Future<void> deleteWallet(String id) async {
    await _txn.delete('wallets', where: 'id = ?', whereArgs: <Object?>[id]);
  }

  @override
  Future<void> unlinkBookTransactionsFromWallet(String walletId) async {
    await _txn.update(
      'book_transactions',
      <String, Object?>{'wallet_id': null, 'wallet_effect': null},
      where: 'wallet_id = ?',
      whereArgs: <Object?>[walletId],
    );
  }

  @override
  Future<void> deleteWalletTransactionHard(String id) async {
    await _txn.delete(
      'wallet_transactions',
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  @override
  Future<String> nextWalletTransactionNumber() async {
    final updated = await _txn.rawUpdate(
      'UPDATE book_counters SET value = value + 1 WHERE name = ?',
      <Object?>['wtx_number'],
    );
    if (updated == 0) {
      await _txn.insert('book_counters', <String, Object?>{
        'name': 'wtx_number',
        'value': 1,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    final value = Sqflite.firstIntValue(
      await _txn.rawQuery(
        'SELECT value FROM book_counters WHERE name = ?',
        <Object?>['wtx_number'],
      ),
    );
    if (value == null) {
      throw const StorageException(
        code: 'wallet_transaction_counter_missing',
        userMessage: 'تعذر إنشاء رقم للحركة.',
      );
    }
    return 'WTX-${value.toString().padLeft(6, '0')}';
  }

  @override
  Future<void> audit(
    String entityType,
    String entityId,
    String action, {
    String? details,
  }) async {
    await _txn.insert('book_audit_log', <String, Object?>{
      'id': _uuid.v4(),
      'entity_type': entityType,
      'entity_id': entityId,
      'action': action,
      'details': details,
      'created_at': DateTime.now().toUtc().millisecondsSinceEpoch,
    });
  }

  /// Update-then-insert: `INSERT OR REPLACE` would delete the row first and
  /// trip the RESTRICT foreign keys of parents that have children.
  Future<void> _upsert(String table, Map<String, Object?> values) async {
    final id = values['id'];
    final updated = await _txn.update(
      table,
      Map<String, Object?>.of(values)..remove('id'),
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
    if (updated == 0) {
      await _txn.insert(table, values);
    }
  }

  /// Like [_upsert], for a table keyed by [where]/[whereArgs] instead of a
  /// single `id` column (a composite primary key, as `wallet_balances` has).
  Future<void> _upsertWhere(
    String table,
    Map<String, Object?> values, {
    required String where,
    required List<Object?> whereArgs,
  }) async {
    final updated = await _txn.update(
      table,
      values,
      where: where,
      whereArgs: whereArgs,
    );
    if (updated == 0) {
      await _txn.insert(table, values);
    }
  }
}
