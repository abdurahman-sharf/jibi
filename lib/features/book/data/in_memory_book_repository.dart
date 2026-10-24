import 'dart:async';

import '../../../core/models/models.dart';
import '../../../core/repositories/book_repository.dart';
import '../../wallets/domain/wallet_balance.dart';
import '../domain/book_balance.dart';

/// Test double for [BookRepository]. Writes are atomic: an action works on a
/// copy of the state that replaces the real one only when it completes.
class InMemoryBookRepository implements BookRepository {
  _State _state = _State();
  final StreamController<void> _changes = StreamController<void>.broadcast();

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<T> write<T>(Future<T> Function(BookWriter writer) action) async {
    final draft = _state.copy();
    final result = await action(_InMemoryWriter(draft));
    _state = draft;
    if (!_changes.isClosed) {
      _changes.add(null);
    }
    return result;
  }

  @override
  Future<BookCategory?> category(String id) async => _state.categories[id];

  @override
  Future<List<CategorySummary>> categorySummaries({
    bool includeInactive = false,
    bool includeArchived = false,
  }) async {
    final categories =
        _state.categories.values
            .where(
              (category) =>
                  (includeInactive || category.isActive) &&
                  (includeArchived || !category.isArchived),
            )
            .toList()
          ..sort((left, right) {
            final order = left.sortOrder.compareTo(right.sortOrder);
            if (order != 0) return order;
            final created = left.createdAt.compareTo(right.createdAt);
            return created != 0 ? created : left.name.compareTo(right.name);
          });
    return [
      for (final category in categories)
        () {
          final summaries = _summaries(
            categoryId: category.id,
            includeArchived: false,
          );
          return CategorySummary(
            category: category,
            accountCount: summaries.length,
            totals: BookBalanceEngine.currencyTotals(summaries),
          );
        }(),
    ];
  }

  @override
  Future<BookAccount?> account(String id) async => _state.accounts[id];

  @override
  Future<AccountSummary?> accountSummary(String id) async {
    final account = _state.accounts[id];
    return account == null ? null : _summary(account);
  }

  @override
  Future<List<AccountSummary>> accountSummaries({
    String? categoryId,
    bool includeArchived = true,
    bool activeCategoriesOnly = false,
  }) async => [
    for (final summary in _summaries(
      categoryId: categoryId,
      includeArchived: includeArchived,
    ))
      if (!activeCategoriesOnly || _categoryActive(summary.account.categoryId))
        summary,
  ];

  @override
  Future<int> accountCount(String categoryId) async => _state.accounts.values
      .where((account) => account.categoryId == categoryId)
      .length;

  @override
  Future<TransactionPage> transactionPage(
    String accountId, {
    BookTransactionFilter filter = BookTransactionFilter.none,
    BookOrderKey? after,
    int limit = 50,
    bool newestFirst = true,
  }) async {
    final rows = _live(accountId)
        .where((row) => BookBalanceEngine.matches(filter, row))
        .toList()
      ..sort(
        (left, right) => newestFirst
            ? BookOrderKey.of(right).compareTo(BookOrderKey.of(left))
            : BookOrderKey.of(left).compareTo(BookOrderKey.of(right)),
      );
    final start = after == null
        ? 0
        : rows.indexWhere(
            (row) => newestFirst
                ? BookOrderKey.of(row).compareTo(after) < 0
                : BookOrderKey.of(row).compareTo(after) > 0,
          );
    if (start < 0) {
      return const TransactionPage(items: [], hasMore: false);
    }
    final window = rows.skip(start).take(limit + 1).toList();
    return TransactionPage(
      items: List<BookTransaction>.unmodifiable(window.take(limit)),
      hasMore: window.length > limit,
    );
  }

  @override
  Future<List<AccountCurrencyTotals>> filteredTotals(
    String accountId, {
    BookTransactionFilter filter = BookTransactionFilter.none,
  }) async {
    final debit = <String, int>{};
    final credit = <String, int>{};
    final count = <String, int>{};
    for (final row in _live(accountId)) {
      if (!BookBalanceEngine.matches(filter, row)) continue;
      final code = row.currencyCode;
      count[code] = (count[code] ?? 0) + 1;
      if (row.type == EntryType.debit) {
        debit[code] = (debit[code] ?? 0) + row.amountMinor;
      } else {
        credit[code] = (credit[code] ?? 0) + row.amountMinor;
      }
    }
    final codes = count.keys.toList()..sort();
    return List<AccountCurrencyTotals>.unmodifiable([
      for (final code in codes)
        AccountCurrencyTotals(
          currencyCode: code,
          debitMinor: debit[code] ?? 0,
          creditMinor: credit[code] ?? 0,
          transactionCount: count[code]!,
        ),
    ]);
  }

  @override
  Future<List<BookAccountBalance>> accountBalancesOf(String accountId) async =>
      _balancesOfAccount(accountId);

  @override
  Future<List<BookTransaction>> reportTransactions({
    String? categoryId,
    String? accountId,
    String? currencyCode,
    String? toDate,
  }) async {
    final rows = <BookTransaction>[
      for (final row in _state.transactions.values)
        if (!row.isDeleted &&
            (accountId == null || row.accountId == accountId) &&
            (currencyCode == null ||
                row.currencyCode == currencyCode.toUpperCase()) &&
            (categoryId == null ||
                _state.accounts[row.accountId]?.categoryId == categoryId) &&
            (toDate == null || row.date.compareTo(toDate) <= 0))
          row,
    ]..sort((left, right) => BookOrderKey.of(left).compareTo(BookOrderKey.of(right)));
    return List<BookTransaction>.unmodifiable(rows);
  }

  @override
  Future<BookTransaction?> transaction(String id) async {
    final row = _state.transactions[id];
    return row == null ? null : _withAttachments(row);
  }

  @override
  Future<List<BookTransaction>> recentTransactions({int limit = 10}) async {
    final visible = <BookTransaction>[
      for (final row in _state.transactions.values)
        if (!row.isDeleted && _accountVisible(row.accountId)) row,
    ]..sort((left, right) => BookOrderKey.of(right).compareTo(BookOrderKey.of(left)));
    return visible.take(limit).map(_withAttachments).toList(growable: false);
  }

  @override
  Future<BookAuditPage> auditPage({
    String? accountId,
    BookAuditEntity? entity,
    BookAuditEntry? after,
    int limit = 50,
  }) async {
    final matching = <BookAuditEntry>[];
    for (final row in _state.audit) {
      final transaction = row.entity == BookAuditEntity.transaction
          ? _state.transactions[row.entityId]
          : null;
      final rowAccountId = switch (row.entity) {
        BookAuditEntity.transaction => transaction?.accountId,
        BookAuditEntity.account => row.entityId,
        BookAuditEntity.category || BookAuditEntity.wallet => null,
      };
      final account = rowAccountId == null ? null : _state.accounts[rowAccountId];
      if (entity != null && row.entity != entity) continue;
      if (accountId != null && account?.id != accountId) continue;
      if (after != null &&
          (row.at.isAfter(after.createdAt) ||
              (row.at.isAtSameMomentAs(after.createdAt) &&
                  row.sequence >= after.sequence))) {
        continue;
      }
      matching.add(
        BookAuditEntry(
          id: 'audit-${row.sequence}',
          sequence: row.sequence,
          entity: row.entity,
          entityId: row.entityId,
          action: row.action,
          details: row.details,
          createdAt: row.at,
          accountId: account?.id,
          accountName: account?.name,
          currencyCode: transaction?.currencyCode,
          categoryName: row.entity == BookAuditEntity.category
              ? _state.categories[row.entityId]?.name
              : null,
          transactionNumber: transaction?.number,
        ),
      );
    }
    matching.sort((left, right) {
      final time = right.createdAt.compareTo(left.createdAt);
      return time != 0 ? time : right.sequence.compareTo(left.sequence);
    });
    return BookAuditPage(
      items: List<BookAuditEntry>.unmodifiable(matching.take(limit)),
      hasMore: matching.length > limit,
    );
  }

  @override
  Future<List<CurrencyTotals>> netPosition() async {
    final summaries = [
      for (final account in _state.accounts.values)
        if (account.status != BookAccountStatus.archived &&
            _categoryActive(account.categoryId))
          _summary(account),
    ];
    return BookBalanceEngine.currencyTotals(summaries);
  }

  /// Legacy vault files are not modelled in memory.
  final Map<String, DocumentFile> legacyFiles = <String, DocumentFile>{};

  @override
  Future<DocumentFile?> legacyDocumentFile(String documentFileId) async =>
      legacyFiles[documentFileId];

  @override
  Future<int> countBalanceMismatches(String accountId) async {
    final account = _state.accounts[accountId];
    if (account == null) return 0;
    final openings = {
      for (final balance in _balancesOfAccount(accountId))
        balance.currencyCode: balance.openingSignedMinor,
    };
    final rows = _live(accountId)
      ..sort((left, right) => BookOrderKey.of(left).compareTo(BookOrderKey.of(right)));
    // Each currency is checked against its own running balance.
    final byCurrency = <String, List<BookTransaction>>{};
    for (final row in rows) {
      (byCurrency[row.currencyCode] ??= []).add(row);
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
  Future<Wallet?> wallet(String id) async => _state.wallets[id];

  @override
  Future<WalletSummary?> walletSummary(String id) async {
    final wallet = _state.wallets[id];
    return wallet == null ? null : _walletSummary(wallet);
  }

  @override
  Future<List<WalletSummary>> walletSummaries({
    bool includeArchived = true,
  }) async {
    final wallets =
        _state.wallets.values
            .where(
              (wallet) =>
                  includeArchived || wallet.status != WalletStatus.archived,
            )
            .toList()
          ..sort((left, right) {
            if (left.isMain != right.isMain) return left.isMain ? -1 : 1;
            final order = left.sortOrder.compareTo(right.sortOrder);
            if (order != 0) return order;
            return left.name.toLowerCase().compareTo(right.name.toLowerCase());
          });
    return [for (final wallet in wallets) _walletSummary(wallet)];
  }

  @override
  Future<List<WalletBalance>> walletBalancesOf(String walletId) async =>
      _balancesOf(walletId);

  @override
  Future<int> countWalletBalanceMismatches(String walletId) async {
    final wallet = _state.wallets[walletId];
    if (wallet == null) return 0;
    final openings = {
      for (final balance in _balancesOf(walletId))
        balance.currencyCode: balance.openingMinor,
    };
    final rows = _liveWallet(walletId)
      ..sort(
        (left, right) =>
            WalletOrderKey.of(left).compareTo(WalletOrderKey.of(right)),
      );
    // Each currency is checked against its own running balance.
    final byCurrency = <String, List<WalletTransaction>>{};
    for (final row in rows) {
      (byCurrency[row.currencyCode] ??= []).add(row);
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
    final summaries = [
      for (final wallet in _state.wallets.values)
        if (wallet.status != WalletStatus.archived) _walletSummary(wallet),
    ];
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
    final rows = _liveWallet(walletId, currencyCode: currencyCode)
        .where((row) => WalletBalanceEngine.matches(filter, row))
        .toList()
      ..sort(
        (left, right) => newestFirst
            ? WalletOrderKey.of(right).compareTo(WalletOrderKey.of(left))
            : WalletOrderKey.of(left).compareTo(WalletOrderKey.of(right)),
      );
    final start = after == null
        ? 0
        : rows.indexWhere(
            (row) => newestFirst
                ? WalletOrderKey.of(row).compareTo(after) < 0
                : WalletOrderKey.of(row).compareTo(after) > 0,
          );
    if (start < 0) {
      return const WalletTransactionPage(items: [], hasMore: false);
    }
    final window = rows.skip(start).take(limit + 1).toList();
    return WalletTransactionPage(
      items: List<WalletTransaction>.unmodifiable(window.take(limit)),
      hasMore: window.length > limit,
    );
  }

  @override
  Future<WalletTransaction?> walletTransaction(String id) async =>
      _state.walletTransactions[id];

  @override
  Future<List<WalletTransaction>> walletReportTransactions(
    String walletId, {
    String? currencyCode,
    String? toDate,
  }) async {
    final rows = <WalletTransaction>[
      for (final row in _liveWallet(walletId, currencyCode: currencyCode))
        if (toDate == null || row.date.compareTo(toDate) <= 0) row,
    ]..sort(
      (left, right) => WalletOrderKey.of(left).compareTo(WalletOrderKey.of(right)),
    );
    return List<WalletTransaction>.unmodifiable(rows);
  }

  @override
  Future<void> dispose() async {
    await _changes.close();
  }

  bool _categoryActive(String categoryId) {
    final category = _state.categories[categoryId];
    return category != null && category.isActive && !category.isArchived;
  }

  bool _accountVisible(String accountId) {
    final account = _state.accounts[accountId];
    return account != null && _categoryActive(account.categoryId);
  }

  List<BookTransaction> _live(String accountId) => [
    for (final row in _state.transactions.values)
      if (row.accountId == accountId && !row.isDeleted) _withAttachments(row),
  ];

  List<WalletTransaction> _liveWallet(String walletId, {String? currencyCode}) => [
    for (final row in _state.walletTransactions.values)
      if (row.walletId == walletId &&
          !row.isDeleted &&
          (currencyCode == null ||
              row.currencyCode == currencyCode.toUpperCase()))
        row,
  ];

  List<WalletBalance> _balancesOf(String walletId) {
    final balances = [
      for (final balance in _state.walletBalances.values)
        if (balance.walletId == walletId) balance,
    ]..sort((left, right) {
      final order = left.sortOrder.compareTo(right.sortOrder);
      return order != 0 ? order : left.currencyCode.compareTo(right.currencyCode);
    });
    return balances;
  }

  WalletSummary _walletSummary(Wallet wallet) {
    final balances = _balancesOf(wallet.id);
    final movements = _state.walletTransactions.values.where(
      (row) => row.walletId == wallet.id,
    );
    var totalCount = 0;
    final currencyBalances = <WalletCurrencyBalance>[
      for (final balance in balances)
        () {
          final count = movements
              .where((row) => !row.isDeleted && row.currencyCode == balance.currencyCode)
              .length;
          totalCount += count;
          return WalletCurrencyBalance(
            currencyCode: balance.currencyCode,
            openingMinor: balance.openingMinor,
            balanceMinor: WalletBalanceEngine.balanceOf(balance, movements),
            transactionCount: count,
          );
        }(),
    ];
    return WalletSummary(
      wallet: wallet,
      balances: currencyBalances,
      transactionCount: totalCount,
    );
  }

  BookTransaction _withAttachments(BookTransaction row) => row.copyWith(
    attachments: List<BookAttachment>.unmodifiable(
      _state.attachments.values.where((item) => item.transactionId == row.id),
    ),
    updatedAt: row.updatedAt,
  );

  List<BookAccountBalance> _balancesOfAccount(String accountId) =>
      [
        for (final balance in _state.accountBalances.values)
          if (balance.accountId == accountId) balance,
      ]..sort((left, right) => left.currencyCode.compareTo(right.currencyCode));

  AccountSummary _summary(BookAccount account) => AccountSummary(
    account: account,
    currencies: BookBalanceEngine.totalsOf(
      _balancesOfAccount(account.id),
      _state.transactions.values.where((row) => row.accountId == account.id),
    ),
  );

  List<AccountSummary> _summaries({
    String? categoryId,
    required bool includeArchived,
  }) {
    final accounts =
        _state.accounts.values
            .where(
              (account) =>
                  (categoryId == null || account.categoryId == categoryId) &&
                  (includeArchived ||
                      account.status != BookAccountStatus.archived),
            )
            .toList()
          ..sort(
            (left, right) =>
                left.name.toLowerCase().compareTo(right.name.toLowerCase()),
          );
    return [for (final account in accounts) _summary(account)];
  }
}

final class _State {
  final Map<String, BookCategory> categories = <String, BookCategory>{};
  final Map<String, BookAccount> accounts = <String, BookAccount>{};
  final Map<String, BookTransaction> transactions = <String, BookTransaction>{};
  final Map<String, BookAttachment> attachments = <String, BookAttachment>{};

  /// Keyed `'$accountId|$currencyCode'`.
  final Map<String, BookAccountBalance> accountBalances =
      <String, BookAccountBalance>{};
  final Map<String, Wallet> wallets = <String, Wallet>{};

  /// Keyed `'$walletId|$currencyCode'`.
  final Map<String, WalletBalance> walletBalances = <String, WalletBalance>{};
  final Map<String, WalletTransaction> walletTransactions =
      <String, WalletTransaction>{};
  final List<_AuditRow> audit = <_AuditRow>[];
  int counter = 0;
  int walletCounter = 0;
  int auditSequence = 0;

  _State copy() {
    final next = _State()
      ..categories.addAll(categories)
      ..accounts.addAll(accounts)
      ..transactions.addAll(transactions)
      ..attachments.addAll(attachments)
      ..accountBalances.addAll(accountBalances)
      ..wallets.addAll(wallets)
      ..walletBalances.addAll(walletBalances)
      ..walletTransactions.addAll(walletTransactions)
      ..audit.addAll(audit)
      ..counter = counter
      ..walletCounter = walletCounter
      ..auditSequence = auditSequence;
    return next;
  }
}

final class _InMemoryWriter implements BookWriter {
  _InMemoryWriter(this._state);

  final _State _state;

  @override
  Future<BookCategory?> category(String id) async => _state.categories[id];

  @override
  Future<BookAccount?> account(String id) async => _state.accounts[id];

  @override
  Future<BookTransaction?> transaction(String id) async =>
      _state.transactions[id];

  @override
  Future<List<BookTransaction>> accountTransactions(
    String accountId, {
    required String currencyCode,
    BookOrderKey? from,
  }) async =>
      [
        for (final row in _state.transactions.values)
          if (row.accountId == accountId &&
              row.currencyCode == currencyCode.toUpperCase() &&
              !row.isDeleted &&
              (from == null || BookOrderKey.of(row).compareTo(from) >= 0))
            row,
      ]..sort((left, right) => BookOrderKey.of(left).compareTo(BookOrderKey.of(right)));

  @override
  Future<BookTransaction?> previousTransaction(
    String accountId,
    String currencyCode,
    BookOrderKey key,
  ) async {
    BookTransaction? best;
    for (final row in _state.transactions.values) {
      if (row.accountId != accountId ||
          row.currencyCode != currencyCode.toUpperCase() ||
          row.isDeleted ||
          BookOrderKey.of(row).compareTo(key) >= 0) {
        continue;
      }
      if (best == null || BookOrderKey.of(row).compareTo(BookOrderKey.of(best)) > 0) {
        best = row;
      }
    }
    return best;
  }

  @override
  Future<int> categoryAccountCount(String categoryId) async => _state
      .accounts
      .values
      .where((account) => account.categoryId == categoryId)
      .length;

  @override
  Future<List<BookAccountBalance>> accountBalances(String accountId) async => [
    for (final balance in _state.accountBalances.values)
      if (balance.accountId == accountId) balance,
  ]..sort((left, right) => left.currencyCode.compareTo(right.currencyCode));

  static String _accountBalanceKey(String accountId, String currencyCode) =>
      '$accountId|${currencyCode.toUpperCase()}';

  @override
  Future<BookAccountBalance?> accountBalance(
    String accountId,
    String currencyCode,
  ) async => _state.accountBalances[_accountBalanceKey(accountId, currencyCode)];

  @override
  Future<void> putAccountBalance(BookAccountBalance balance) async =>
      _state.accountBalances[_accountBalanceKey(
            balance.accountId,
            balance.currencyCode,
          )] =
          balance;

  @override
  Future<void> deleteAccountBalance(
    String accountId,
    String currencyCode,
  ) async => _state.accountBalances.remove(
    _accountBalanceKey(accountId, currencyCode),
  );

  @override
  Future<int> accountTransactionCount(
    String accountId, {
    String? currencyCode,
  }) async => _state.transactions.values
      .where(
        (row) =>
            row.accountId == accountId &&
            (currencyCode == null ||
                row.currencyCode == currencyCode.toUpperCase()),
      )
      .length;

  @override
  Future<List<BookAccount>> accountsOfCategory(String categoryId) async => [
    for (final account in _state.accounts.values)
      if (account.categoryId == categoryId) account,
  ];

  @override
  Future<List<BookTransaction>> allTransactionsOfAccount(
    String accountId,
  ) async => [
    for (final row in _state.transactions.values)
      if (row.accountId == accountId) row,
  ];

  @override
  Future<List<BookAttachment>> attachments(String transactionId) async => [
    for (final item in _state.attachments.values)
      if (item.transactionId == transactionId) item,
  ];

  @override
  Future<BookAttachment?> attachment(String id) async => _state.attachments[id];

  @override
  Future<void> putCategory(BookCategory category) async =>
      _state.categories[category.id] = category;

  @override
  Future<void> putAccount(BookAccount account) async =>
      _state.accounts[account.id] = account;

  @override
  Future<void> putTransaction(BookTransaction transaction) async =>
      _state.transactions[transaction.id] = transaction;

  @override
  Future<void> updateBalances(Map<String, int> balanceAfterByTransactionId) async {
    balanceAfterByTransactionId.forEach((id, balance) {
      final row = _state.transactions[id];
      if (row != null) {
        _state.transactions[id] = row.copyWith(
          balanceAfter: balance,
          updatedAt: row.updatedAt,
        );
      }
    });
  }

  @override
  Future<void> putAttachment(BookAttachment attachment) async =>
      _state.attachments[attachment.id] = attachment;

  @override
  Future<void> removeAttachment(String id) async =>
      _state.attachments.remove(id);

  @override
  Future<void> deleteCategory(String id) async => _state.categories.remove(id);

  @override
  Future<void> deleteAccount(String id) async {
    _state.accounts.remove(id);
    // Mirrors book_account_balances' ON DELETE CASCADE on account_id.
    _state.accountBalances.removeWhere((_, balance) => balance.accountId == id);
  }

  @override
  Future<void> deleteTransactionHard(String id) async {
    _state.transactions.remove(id);
    // Mirrors book_attachments' ON DELETE CASCADE on transaction_id.
    _state.attachments.removeWhere(
      (_, attachment) => attachment.transactionId == id,
    );
  }

  @override
  Future<String> nextTransactionNumber() async {
    _state.counter++;
    return 'TX-${_state.counter.toString().padLeft(6, '0')}';
  }

  @override
  Future<Wallet?> wallet(String id) async => _state.wallets[id];

  @override
  Future<Wallet?> mainWallet() async {
    for (final wallet in _state.wallets.values) {
      if (wallet.isMain) return wallet;
    }
    return null;
  }

  static String _balanceKey(String walletId, String currencyCode) =>
      '$walletId|${currencyCode.toUpperCase()}';

  @override
  Future<List<WalletBalance>> walletBalances(String walletId) async {
    final balances = [
      for (final balance in _state.walletBalances.values)
        if (balance.walletId == walletId) balance,
    ]..sort((left, right) {
      final order = left.sortOrder.compareTo(right.sortOrder);
      return order != 0 ? order : left.currencyCode.compareTo(right.currencyCode);
    });
    return balances;
  }

  @override
  Future<WalletBalance?> walletBalance(
    String walletId,
    String currencyCode,
  ) async => _state.walletBalances[_balanceKey(walletId, currencyCode)];

  @override
  Future<void> putWalletBalance(WalletBalance balance) async =>
      _state.walletBalances[_balanceKey(balance.walletId, balance.currencyCode)] =
          balance;

  @override
  Future<void> deleteWalletBalance(
    String walletId,
    String currencyCode,
  ) async => _state.walletBalances.remove(_balanceKey(walletId, currencyCode));

  @override
  Future<void> deleteWalletBalances(String walletId) async =>
      _state.walletBalances.removeWhere(
        (_, balance) => balance.walletId == walletId,
      );

  @override
  Future<WalletTransaction?> walletTransaction(String id) async =>
      _state.walletTransactions[id];

  @override
  Future<List<WalletTransaction>> walletTransactionsOf(
    String walletId, {
    required String currencyCode,
    WalletOrderKey? from,
  }) async {
    final code = currencyCode.toUpperCase();
    return [
      for (final row in _state.walletTransactions.values)
        if (row.walletId == walletId &&
            row.currencyCode == code &&
            !row.isDeleted &&
            (from == null || WalletOrderKey.of(row).compareTo(from) >= 0))
          row,
    ]..sort(
      (left, right) =>
          WalletOrderKey.of(left).compareTo(WalletOrderKey.of(right)),
    );
  }

  @override
  Future<WalletTransaction?> previousWalletTransaction(
    String walletId,
    String currencyCode,
    WalletOrderKey key,
  ) async {
    final code = currencyCode.toUpperCase();
    WalletTransaction? best;
    for (final row in _state.walletTransactions.values) {
      if (row.walletId != walletId ||
          row.currencyCode != code ||
          row.isDeleted ||
          WalletOrderKey.of(row).compareTo(key) >= 0) {
        continue;
      }
      if (best == null ||
          WalletOrderKey.of(row).compareTo(WalletOrderKey.of(best)) > 0) {
        best = row;
      }
    }
    return best;
  }

  @override
  Future<List<WalletTransaction>> allWalletTransactionsOf(
    String walletId,
  ) async => [
    for (final row in _state.walletTransactions.values)
      if (row.walletId == walletId) row,
  ];

  @override
  Future<List<WalletTransaction>> walletTransactionsInLegGroup(
    String legGroupId,
  ) async => [
    for (final row in _state.walletTransactions.values)
      if (row.legGroupId == legGroupId) row,
  ];

  @override
  Future<WalletTransaction?> walletTransactionForBookTransaction(
    String bookTransactionId,
  ) async {
    for (final row in _state.walletTransactions.values) {
      if (row.linkedBookTransactionId == bookTransactionId) return row;
    }
    return null;
  }

  @override
  Future<int> walletTransactionCount(
    String walletId, {
    String? currencyCode,
  }) async {
    final code = currencyCode?.toUpperCase();
    return _state.walletTransactions.values
        .where(
          (row) =>
              row.walletId == walletId &&
              (code == null || row.currencyCode == code),
        )
        .length;
  }

  @override
  Future<void> putWallet(Wallet wallet) async =>
      _state.wallets[wallet.id] = wallet;

  @override
  Future<void> putWalletTransaction(WalletTransaction transaction) async =>
      _state.walletTransactions[transaction.id] = transaction;

  @override
  Future<void> updateWalletBalances(
    Map<String, int> balanceAfterByWalletTransactionId,
  ) async {
    balanceAfterByWalletTransactionId.forEach((id, balance) {
      final row = _state.walletTransactions[id];
      if (row != null) {
        _state.walletTransactions[id] = row.copyWith(
          balanceAfter: balance,
          updatedAt: row.updatedAt,
        );
      }
    });
  }

  @override
  Future<void> unlinkBookTransactionsFromWallet(String walletId) async {
    for (final row in _state.transactions.values.toList()) {
      if (row.walletId != walletId) continue;
      _state.transactions[row.id] = row.copyWith(
        walletId: () => null,
        walletEffect: () => null,
        updatedAt: row.updatedAt,
      );
    }
  }

  @override
  Future<void> deleteWallet(String id) async {
    _state.wallets.remove(id);
    // Mirrors wallet_balances' ON DELETE CASCADE on wallet_id.
    _state.walletBalances.removeWhere(
      (_, balance) => balance.walletId == id,
    );
  }

  @override
  Future<void> deleteWalletTransactionHard(String id) async =>
      _state.walletTransactions.remove(id);

  @override
  Future<String> nextWalletTransactionNumber() async {
    _state.walletCounter++;
    return 'WTX-${_state.walletCounter.toString().padLeft(6, '0')}';
  }

  @override
  Future<void> audit(
    String entityType,
    String entityId,
    String action, {
    String? details,
  }) async {
    final kind = BookAuditEntity.fromDb(entityType);
    if (kind == null) return;
    _state.audit.add(
      _AuditRow(
        sequence: ++_state.auditSequence,
        entity: kind,
        entityId: entityId,
        action: action,
        details: details,
        at: DateTime.now().toUtc(),
      ),
    );
  }
}

final class _AuditRow {
  const _AuditRow({
    required this.sequence,
    required this.entity,
    required this.entityId,
    required this.action,
    required this.at,
    this.details,
  });

  final int sequence;
  final BookAuditEntity entity;
  final String entityId;
  final String action;
  final String? details;
  final DateTime at;
}
