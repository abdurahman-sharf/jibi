import '../../../core/models/models.dart';
import '../../../core/repositories/book_repository.dart';

/// Pure balance rules for wallets. Nothing here touches storage.
///
/// One convention everywhere: money coming in is positive, money going out is
/// negative. The balance of one (wallet, currency) is
/// `opening + incoming - outgoing`, computed independently per currency.
final class WalletBalanceEngine {
  const WalletBalanceEngine._();

  /// `balance_after` for every movement of [sortedAscending] (already scoped
  /// to one wallet and one currency), starting from [seed] (the opening
  /// balance, or the balance right before the first row).
  static List<int> recompute(
    int seed,
    Iterable<WalletTransaction> sortedAscending,
  ) {
    var running = seed;
    final balances = <int>[];
    for (final transaction in sortedAscending) {
      running += transaction.signedMinor;
      balances.add(running);
    }
    return balances;
  }

  /// Balance of one (wallet, currency) from its live movements. [movements]
  /// may span other currencies of the same wallet too — anything not in
  /// [balance]'s currency is ignored.
  static int balanceOf(
    WalletBalance balance,
    Iterable<WalletTransaction> movements,
  ) {
    var running = balance.openingMinor;
    for (final movement in movements) {
      if (movement.isDeleted) continue;
      if (movement.currencyCode != balance.currencyCode) continue;
      running += movement.signedMinor;
    }
    return running;
  }

  /// Totals per currency, across every non-archived wallet. Different
  /// currencies are never added.
  static List<WalletCurrencyTotal> currencyTotals(
    Iterable<WalletSummary> summaries,
  ) {
    final totals = <String, int>{};
    final counts = <String, int>{};
    for (final summary in summaries) {
      if (summary.wallet.status == WalletStatus.archived) continue;
      for (final balance in summary.balances) {
        final code = balance.currencyCode;
        totals[code] = (totals[code] ?? 0) + balance.balanceMinor;
        counts[code] = (counts[code] ?? 0) + 1;
      }
    }
    final codes = counts.keys.toList()..sort();
    return List<WalletCurrencyTotal>.unmodifiable([
      for (final code in codes)
        WalletCurrencyTotal(
          currencyCode: code,
          totalMinor: totals[code]!,
          walletCount: counts[code]!,
        ),
    ]);
  }

  /// Whether [transaction] passes [filter]. Used by the in-memory repository;
  /// the SQLite repository builds the equivalent SQL.
  static bool matches(
    WalletTransactionFilter filter,
    WalletTransaction transaction,
  ) {
    if (filter.type != null && transaction.type != filter.type) return false;
    if (filter.fromDate != null &&
        transaction.date.compareTo(filter.fromDate!) < 0) {
      return false;
    }
    if (filter.toDate != null &&
        transaction.date.compareTo(filter.toDate!) > 0) {
      return false;
    }
    return true;
  }

  /// Recomputes the stored `balance_after` of one (wallet, currency) inside a
  /// write.
  ///
  /// With [from], only rows at or after that key are touched, seeded from the
  /// row just before it. Without it the whole (wallet, currency) sequence is
  /// rebuilt from the opening balance. Only rows whose value actually changes
  /// are written.
  static Future<void> recomputeWalletCurrency(
    BookWriter writer,
    WalletBalance balance, {
    WalletOrderKey? from,
  }) async {
    var seed = balance.openingMinor;
    if (from != null) {
      final previous = await writer.previousWalletTransaction(
        balance.walletId,
        balance.currencyCode,
        from,
      );
      if (previous != null) {
        seed = previous.balanceAfter;
      }
    }
    final rows = await writer.walletTransactionsOf(
      balance.walletId,
      currencyCode: balance.currencyCode,
      from: from,
    );
    final balances = recompute(seed, rows);
    final changed = <String, int>{
      for (var index = 0; index < rows.length; index++)
        if (rows[index].balanceAfter != balances[index])
          rows[index].id: balances[index],
    };
    if (changed.isNotEmpty) {
      await writer.updateWalletBalances(changed);
    }
  }

  /// Recomputes every currency of [walletId]. Used by cascade delete and by
  /// an opening-balance edit that could touch more than one currency; an edit
  /// to a single currency should call [recomputeWalletCurrency] directly so
  /// the other currencies' sequences are left untouched.
  static Future<void> recomputeWallet(BookWriter writer, String walletId) async {
    for (final balance in await writer.walletBalances(walletId)) {
      await recomputeWalletCurrency(writer, balance);
    }
  }
}
