import '../../../core/models/models.dart';
import '../../../core/repositories/book_repository.dart';

/// Pure balance rules for the accounts book. Nothing here touches storage.
///
/// One convention everywhere: a debit is positive (the counter-party owes the
/// user), a credit is negative. The balance of an account IN ONE CURRENCY is
/// `opening + debits - credits` over that currency's transactions only. An
/// account that uses several currencies has one independent balance per
/// currency; two currencies are never added, converted or netted.
final class BookBalanceEngine {
  const BookBalanceEngine._();

  /// `balance_after` for every transaction of [sortedAscending], starting from
  /// [seed] (the opening balance, or the balance right before the first row).
  /// The rows must all be of the same account and currency.
  static List<int> recompute(
    int seed,
    Iterable<BookTransaction> sortedAscending,
  ) {
    var running = seed;
    final balances = <int>[];
    for (final transaction in sortedAscending) {
      running += transaction.signedMinor;
      balances.add(running);
    }
    return balances;
  }

  /// One account's position per currency from its opening [balances] and its
  /// [transactions] (deleted ones ignored). Only currencies the account uses —
  /// an opening balance or at least one live transaction — are returned,
  /// sorted by code. A transaction's currency is grouped on its own: nothing
  /// is ever added across currencies.
  static List<AccountCurrencyTotals> totalsOf(
    Iterable<BookAccountBalance> balances,
    Iterable<BookTransaction> transactions,
  ) {
    final openings = <String, BookAccountBalance>{
      for (final balance in balances) balance.currencyCode: balance,
    };
    final debit = <String, int>{};
    final credit = <String, int>{};
    final count = <String, int>{};
    for (final transaction in transactions) {
      if (transaction.isDeleted) continue;
      final code = transaction.currencyCode;
      count[code] = (count[code] ?? 0) + 1;
      if (transaction.type == EntryType.debit) {
        debit[code] = (debit[code] ?? 0) + transaction.amountMinor;
      } else {
        credit[code] = (credit[code] ?? 0) + transaction.amountMinor;
      }
    }
    final codes = <String>{...openings.keys, ...count.keys}.toList()..sort();
    final lines = <AccountCurrencyTotals>[];
    for (final code in codes) {
      final opening = openings[code];
      final line = AccountCurrencyTotals(
        currencyCode: code,
        openingMinor: opening?.openingMinor ?? 0,
        openingType: opening?.openingType ?? OpeningType.zero,
        debitMinor:
            (debit[code] ?? 0) +
            (opening?.openingType == OpeningType.debit
                ? opening!.openingMinor
                : 0),
        creditMinor:
            (credit[code] ?? 0) +
            (opening?.openingType == OpeningType.credit
                ? opening!.openingMinor
                : 0),
        transactionCount: count[code] ?? 0,
      );
      if (line.isUsed) lines.add(line);
    }
    return List<AccountCurrencyTotals>.unmodifiable(lines);
  }

  /// Sums accounts per currency. Different currencies are never added: an
  /// account counts once in every currency it uses.
  static List<CurrencyTotals> currencyTotals(
    Iterable<AccountSummary> summaries,
  ) {
    final debit = <String, int>{};
    final credit = <String, int>{};
    final accounts = <String, int>{};
    for (final summary in summaries) {
      for (final line in summary.currencies) {
        final code = line.currencyCode;
        debit[code] = (debit[code] ?? 0) + line.debitMinor;
        credit[code] = (credit[code] ?? 0) + line.creditMinor;
        accounts[code] = (accounts[code] ?? 0) + 1;
      }
    }
    final codes = accounts.keys.toList()..sort();
    return List<CurrencyTotals>.unmodifiable([
      for (final code in codes)
        CurrencyTotals(
          currencyCode: code,
          debitMinor: debit[code]!,
          creditMinor: credit[code]!,
          accountCount: accounts[code]!,
        ),
    ]);
  }

  /// Whether [transaction] passes [filter]. Used by the in-memory repository;
  /// the SQLite repository builds the equivalent SQL.
  static bool matches(BookTransactionFilter filter, BookTransaction transaction) {
    if (filter.type != null && transaction.type != filter.type) return false;
    if (filter.currencyCode != null &&
        transaction.currencyCode != filter.currencyCode!.toUpperCase()) {
      return false;
    }
    if (filter.fromDate != null && transaction.date.compareTo(filter.fromDate!) < 0) {
      return false;
    }
    if (filter.toDate != null && transaction.date.compareTo(filter.toDate!) > 0) {
      return false;
    }
    if (filter.minAmountMinor != null &&
        transaction.amountMinor < filter.minAmountMinor!) {
      return false;
    }
    if (filter.maxAmountMinor != null &&
        transaction.amountMinor > filter.maxAmountMinor!) {
      return false;
    }
    if (filter.withAttachments && transaction.attachments.isEmpty) {
      return false;
    }
    if (filter.walletId != null && transaction.walletId != filter.walletId) {
      return false;
    }
    final text = filter.text?.trim().toLowerCase();
    if (text != null && text.isNotEmpty) {
      final haystacks = <String?>[
        transaction.details,
        transaction.notes,
        transaction.number,
        transaction.date,
        transaction.amountMinor.toString(),
      ];
      final textHit = haystacks.any(
        (value) => value != null && value.toLowerCase().contains(text),
      );
      final amountHit =
          filter.textAmountsMinor?[transaction.currencyCode] ==
          transaction.amountMinor;
      if (!textHit && !amountHit) return false;
    }
    return true;
  }

  /// Makes sure [accountId] has a balance row for [currencyCode] — created at
  /// an opening of zero, at its first transaction in that currency — and
  /// returns it. The row is what declares that the account uses the currency.
  static Future<BookAccountBalance> ensureBalance(
    BookWriter writer,
    String accountId,
    String currencyCode,
    DateTime now,
  ) async {
    final existing = await writer.accountBalance(accountId, currencyCode);
    if (existing != null) return existing;
    final created = BookAccountBalance(
      accountId: accountId,
      currencyCode: currencyCode,
      createdAt: now,
      updatedAt: now,
    );
    await writer.putAccountBalance(created);
    return created;
  }

  /// Recomputes the stored `balance_after` of ONE currency of an account
  /// inside a write. Other currencies of the same account are not touched.
  ///
  /// With [from], only rows at or after that key are touched, seeded from the
  /// row just before it (in the same currency). Without it the currency is
  /// rebuilt from its opening balance. Only rows whose value actually changes
  /// are written.
  static Future<void> recomputeCurrency(
    BookWriter writer,
    String accountId,
    String currencyCode, {
    BookOrderKey? from,
  }) async {
    final opening = await writer.accountBalance(accountId, currencyCode);
    var seed = opening?.openingSignedMinor ?? 0;
    if (from != null) {
      final previous = await writer.previousTransaction(
        accountId,
        currencyCode,
        from,
      );
      if (previous != null) {
        seed = previous.balanceAfter;
      }
    }
    final rows = await writer.accountTransactions(
      accountId,
      currencyCode: currencyCode,
      from: from,
    );
    final balances = recompute(seed, rows);
    final changed = <String, int>{
      for (var index = 0; index < rows.length; index++)
        if (rows[index].balanceAfter != balances[index])
          rows[index].id: balances[index],
    };
    if (changed.isNotEmpty) {
      await writer.updateBalances(changed);
    }
  }

  /// Rebuilds every currency of [accountId] from its opening balance (each one
  /// on its own).
  static Future<void> recomputeAccount(
    BookWriter writer,
    String accountId,
  ) async {
    for (final balance in await writer.accountBalances(accountId)) {
      await recomputeCurrency(writer, accountId, balance.currencyCode);
    }
  }
}
