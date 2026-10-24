import '../models/models.dart';

/// Persistence for the accounts book.
///
/// Reads are plain queries; every write goes through [write], one atomic unit
/// of work. The business rules (validation, running balances, numbering) live
/// in the controllers and are therefore identical for every implementation.
abstract interface class BookRepository {
  /// Emits after every committed [write].
  Stream<void> get changes;

  Future<T> write<T>(Future<T> Function(BookWriter writer) action);

  Future<BookCategory?> category(String id);

  /// Categories with per-currency totals of their non-archived accounts, in
  /// display order.
  Future<List<CategorySummary>> categorySummaries({
    bool includeInactive = false,
    bool includeArchived = false,
  });

  Future<BookAccount?> account(String id);
  Future<AccountSummary?> accountSummary(String id);

  /// Accounts with totals ordered by name. [categoryId] null means all
  /// categories; [activeCategoriesOnly] leaves out the accounts of categories
  /// that are switched off or archived (what the app screens show).
  Future<List<AccountSummary>> accountSummaries({
    String? categoryId,
    bool includeArchived = true,
    bool activeCategoriesOnly = false,
  });

  Future<int> accountCount(String categoryId);

  /// The audit log, newest first. [accountId] keeps the entries of that
  /// account and of its transactions; [entity] keeps one kind of entry;
  /// [after] continues after an entry of an earlier page.
  Future<BookAuditPage> auditPage({
    String? accountId,
    BookAuditEntity? entity,
    BookAuditEntry? after,
    int limit = 50,
  });

  /// Transactions (deleted ones excluded) of an account, one page at a time.
  Future<TransactionPage> transactionPage(
    String accountId, {
    BookTransactionFilter filter = BookTransactionFilter.none,
    BookOrderKey? after,
    int limit = 50,
    bool newestFirst = true,
  });

  /// Transaction-only totals and row counts for [filter] (no opening
  /// balance), one entry per currency that has a matching transaction, sorted
  /// by code. Never adds two currencies together.
  Future<List<AccountCurrencyTotals>> filteredTotals(
    String accountId, {
    BookTransactionFilter filter = BookTransactionFilter.none,
  });

  /// Every live transaction of a category ([categoryId]) or of one account
  /// ([accountId]) up to and including [toDate] (`YYYY-MM-DD`), in ascending
  /// order; [currencyCode] narrows to one currency. Reports are built from
  /// these rows, never from stored balances.
  Future<List<BookTransaction>> reportTransactions({
    String? categoryId,
    String? accountId,
    String? currencyCode,
    String? toDate,
  });

  /// One account's opening-balance rows (one per currency it uses, including
  /// currencies whose transactions were all deleted), sorted by code.
  Future<List<BookAccountBalance>> accountBalancesOf(String accountId);

  /// One transaction with its attachments; null when unknown. Deleted rows
  /// are returned too so an undo can restore them.
  Future<BookTransaction?> transaction(String id);

  /// The latest live transactions across every account, newest first.
  Future<List<BookTransaction>> recentTransactions({int limit = 10});

  /// The position of the book per currency over every non-archived account
  /// of an active category: `debitMinor` is the sum of all debit entries
  /// (what people owe the user) and `creditMinor` the sum of all credit
  /// entries (what the user owes), openings included — the same figures the
  /// accounts tab shows, so the two screens always agree.
  Future<List<CurrencyTotals>> netPosition();

  /// The vault file behind an attachment migrated from the legacy ledger
  /// (`document_file_id`); null when it no longer exists.
  Future<DocumentFile?> legacyDocumentFile(String documentFileId);

  /// Number of transactions whose stored `balance_after` disagrees with the
  /// balance recomputed from the transactions of the same (account, currency).
  Future<int> countBalanceMismatches(String accountId);

  Future<Wallet?> wallet(String id);
  Future<WalletSummary?> walletSummary(String id);

  /// Wallets with their running balance per currency, in display order.
  Future<List<WalletSummary>> walletSummaries({bool includeArchived = true});

  /// One wallet's balance rows (one per currency it holds), in display order.
  Future<List<WalletBalance>> walletBalancesOf(String walletId);

  /// Number of wallet movements whose stored `balance_after` disagrees with
  /// the balance recomputed from the live movements of the same (wallet,
  /// currency). Mirrors [countBalanceMismatches] for wallets.
  Future<int> countWalletBalanceMismatches(String walletId);

  /// Total balance per currency over every non-archived wallet. Never sums
  /// across currencies.
  Future<List<WalletCurrencyTotal>> walletTotalsByCurrency();

  /// One wallet's movements (deleted ones excluded), one page at a time.
  /// [currencyCode] narrows to one of the wallet's currencies; null pages
  /// across all of them.
  Future<WalletTransactionPage> walletTransactionPage(
    String walletId, {
    String? currencyCode,
    WalletTransactionFilter filter = WalletTransactionFilter.none,
    WalletOrderKey? after,
    int limit = 50,
    bool newestFirst = true,
  });

  /// One wallet movement; null when unknown. Deleted rows are returned too so
  /// an undo can restore them.
  Future<WalletTransaction?> walletTransaction(String id);

  /// Every live movement of [walletId] up to and including [toDate]
  /// (`YYYY-MM-DD`), in ascending order. [currencyCode] narrows to one of the
  /// wallet's currencies; null returns every currency. The wallet statement
  /// report is built from these rows, never from the stored `balance_after`,
  /// matching [reportTransactions].
  Future<List<WalletTransaction>> walletReportTransactions(
    String walletId, {
    String? currencyCode,
    String? toDate,
  });

  Future<void> dispose();
}

/// Primitives available inside [BookRepository.write].
abstract interface class BookWriter {
  Future<BookCategory?> category(String id);
  Future<BookAccount?> account(String id);

  /// Includes deleted rows.
  Future<BookTransaction?> transaction(String id);

  /// Live transactions of one (account, currency) in ascending [BookOrderKey]
  /// order, starting at [from] (inclusive) or at the beginning.
  Future<List<BookTransaction>> accountTransactions(
    String accountId, {
    required String currencyCode,
    BookOrderKey? from,
  });

  /// The last live transaction of one (account, currency) strictly before
  /// [key].
  Future<BookTransaction?> previousTransaction(
    String accountId,
    String currencyCode,
    BookOrderKey key,
  );

  /// An account's opening-balance rows (one per currency it uses), sorted by
  /// code.
  Future<List<BookAccountBalance>> accountBalances(String accountId);

  /// One (account, currency) row; null when the account does not use it.
  Future<BookAccountBalance?> accountBalance(
    String accountId,
    String currencyCode,
  );

  Future<void> putAccountBalance(BookAccountBalance balance);

  /// Removes one (account, currency) row. Callers must ensure it has no
  /// transactions first.
  Future<void> deleteAccountBalance(String accountId, String currencyCode);

  Future<int> categoryAccountCount(String categoryId);

  /// Rows of the account including deleted ones. [currencyCode] narrows to one
  /// currency; null counts every currency.
  Future<int> accountTransactionCount(String accountId, {String? currencyCode});

  /// Every account of [categoryId], any status. Used by cascade delete.
  Future<List<BookAccount>> accountsOfCategory(String categoryId);

  /// Every transaction of [accountId], live and soft-deleted. Used by cascade
  /// delete to find attachments that need their encrypted files removed.
  Future<List<BookTransaction>> allTransactionsOfAccount(String accountId);

  Future<List<BookAttachment>> attachments(String transactionId);
  Future<BookAttachment?> attachment(String id);

  Future<void> putCategory(BookCategory category);
  Future<void> putAccount(BookAccount account);
  Future<void> putTransaction(BookTransaction transaction);
  Future<void> updateBalances(Map<String, int> balanceAfterByTransactionId);
  Future<void> putAttachment(BookAttachment attachment);
  Future<void> removeAttachment(String id);
  Future<void> deleteCategory(String id);
  Future<void> deleteAccount(String id);

  /// Hard-deletes one transaction row. Its attachments go with it (DB-level
  /// cascade); the caller must remove their encrypted files separately.
  Future<void> deleteTransactionHard(String id);

  /// Next `TX-000001`-style number. Numbers are never reused.
  Future<String> nextTransactionNumber();

  Future<void> audit(
    String entityType,
    String entityId,
    String action, {
    String? details,
  });

  Future<Wallet?> wallet(String id);

  /// The wallet flagged `is_main`, if any.
  Future<Wallet?> mainWallet();

  /// A wallet's balance rows (one per currency it holds), in display order.
  Future<List<WalletBalance>> walletBalances(String walletId);

  /// One (wallet, currency) balance row; null when the wallet does not hold
  /// that currency.
  Future<WalletBalance?> walletBalance(String walletId, String currencyCode);

  Future<void> putWalletBalance(WalletBalance balance);

  /// Removes one (wallet, currency) balance row. Callers must ensure it has
  /// no movements first.
  Future<void> deleteWalletBalance(String walletId, String currencyCode);

  /// Removes every balance row of [walletId]. Used by cascade delete.
  Future<void> deleteWalletBalances(String walletId);

  /// Includes deleted rows.
  Future<WalletTransaction?> walletTransaction(String id);

  /// Live movements of one (wallet, currency) in ascending [WalletOrderKey]
  /// order, starting at [from] (inclusive) or at the beginning.
  Future<List<WalletTransaction>> walletTransactionsOf(
    String walletId, {
    required String currencyCode,
    WalletOrderKey? from,
  });

  /// The last live movement of one (wallet, currency) strictly before [key].
  Future<WalletTransaction?> previousWalletTransaction(
    String walletId,
    String currencyCode,
    WalletOrderKey key,
  );

  /// Every movement of [walletId], live and soft-deleted, across every
  /// currency. Used by cascade delete.
  Future<List<WalletTransaction>> allWalletTransactionsOf(String walletId);

  /// The two legs of a transfer or an exchange (or the one row, for any other
  /// kind).
  Future<List<WalletTransaction>> walletTransactionsInLegGroup(
    String legGroupId,
  );

  /// The `linked` wallet movement created for [bookTransactionId], if any.
  /// Includes a soft-deleted row so undo can find it too.
  Future<WalletTransaction?> walletTransactionForBookTransaction(
    String bookTransactionId,
  );

  /// Rows of the wallet including deleted ones. [currencyCode] narrows to one
  /// currency; null counts every currency.
  Future<int> walletTransactionCount(String walletId, {String? currencyCode});

  Future<void> putWallet(Wallet wallet);
  Future<void> putWalletTransaction(WalletTransaction transaction);
  Future<void> updateWalletBalances(
    Map<String, int> balanceAfterByWalletTransactionId,
  );
  Future<void> deleteWallet(String id);

  /// Clears the wallet link (payment method) of every book transaction paid
  /// through [walletId], live or soft-deleted, so the wallet can be deleted.
  /// Their account balances are unaffected — only the link goes.
  Future<void> unlinkBookTransactionsFromWallet(String walletId);

  /// Hard-deletes one wallet movement row. Used by cascade delete.
  Future<void> deleteWalletTransactionHard(String id);

  /// Next `WTX-000001`-style number. Numbers are never reused.
  Future<String> nextWalletTransactionNumber();
}
