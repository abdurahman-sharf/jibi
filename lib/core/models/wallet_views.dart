import 'wallet.dart';

/// Total order of a wallet's transactions, scoped to one currency (a wallet's
/// currencies each have their own independent sequence). Mirrors
/// [BookOrderKey] one-to-one.
final class WalletOrderKey implements Comparable<WalletOrderKey> {
  const WalletOrderKey({
    required this.date,
    required this.time,
    required this.createdAtMs,
    required this.id,
  });

  factory WalletOrderKey.of(WalletTransaction transaction) => WalletOrderKey(
    date: transaction.date,
    time: transaction.time,
    createdAtMs: transaction.createdAt.toUtc().millisecondsSinceEpoch,
    id: transaction.id,
  );

  final String date;
  final String time;
  final int createdAtMs;
  final String id;

  @override
  int compareTo(WalletOrderKey other) {
    var order = date.compareTo(other.date);
    if (order != 0) return order;
    order = time.compareTo(other.time);
    if (order != 0) return order;
    order = createdAtMs.compareTo(other.createdAtMs);
    if (order != 0) return order;
    return id.compareTo(other.id);
  }

  @override
  bool operator ==(Object other) =>
      other is WalletOrderKey && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(date, time, createdAtMs, id);
}

/// Search and filter options for one wallet's transactions. Deliberately has
/// no currency field: a currency scope is not a filter (it never counts
/// toward [isEmpty]) — pass it as a separate parameter alongside the filter.
final class WalletTransactionFilter {
  const WalletTransactionFilter({
    this.type,
    this.fromDate,
    this.toDate,
  });

  static const none = WalletTransactionFilter();

  final WalletTransactionType? type;

  /// Inclusive `YYYY-MM-DD` bounds.
  final String? fromDate;
  final String? toDate;

  bool get isEmpty => type == null && fromDate == null && toDate == null;

  WalletTransactionFilter copyWith({
    WalletTransactionType? Function()? type,
    String? Function()? fromDate,
    String? Function()? toDate,
  }) => WalletTransactionFilter(
    type: type != null ? type() : this.type,
    fromDate: fromDate != null ? fromDate() : this.fromDate,
    toDate: toDate != null ? toDate() : this.toDate,
  );
}

/// One currency a wallet holds, with its live balance.
final class WalletCurrencyBalance {
  const WalletCurrencyBalance({
    required this.currencyCode,
    required this.openingMinor,
    required this.balanceMinor,
    required this.transactionCount,
  });

  final String currencyCode;
  final int openingMinor;

  /// Opening balance plus every live movement in this currency.
  final int balanceMinor;

  /// Live (non-deleted) transactions of this wallet in this currency.
  final int transactionCount;
}

final class WalletSummary {
  const WalletSummary({
    required this.wallet,
    required this.balances,
    required this.transactionCount,
  });

  final Wallet wallet;

  /// One entry per currency the wallet holds, in display order (sort_order,
  /// then code). Includes zero balances; the UI decides what to hide.
  final List<WalletCurrencyBalance> balances;

  /// Live (non-deleted) movements across every currency of this wallet.
  final int transactionCount;

  int balanceOf(String currencyCode) {
    final code = currencyCode.toUpperCase();
    for (final balance in balances) {
      if (balance.currencyCode == code) return balance.balanceMinor;
    }
    return 0;
  }

  List<String> get currencies => [
    for (final balance in balances) balance.currencyCode,
  ];

  /// Non-zero balances only, in display order.
  List<WalletCurrencyBalance> get nonZero => [
    for (final balance in balances)
      if (balance.balanceMinor != 0) balance,
  ];

  bool get isMultiCurrency => nonZero.length > 1;

  /// The one currency to show on a compact tile: the only non-zero one, else
  /// the largest non-zero balance, else the first balance of any (so a
  /// brand-new wallet with an opening of zero still shows its currency), else
  /// null for a wallet that holds no currency at all yet.
  WalletCurrencyBalance? get primary {
    final live = nonZero;
    if (live.length == 1) return live.single;
    if (live.isNotEmpty) {
      var largest = live.first;
      for (final balance in live.skip(1)) {
        if (balance.balanceMinor.abs() > largest.balanceMinor.abs()) {
          largest = balance;
        }
      }
      return largest;
    }
    return balances.isEmpty ? null : balances.first;
  }
}

/// Total wallet balance of one currency, across every active wallet.
final class WalletCurrencyTotal {
  const WalletCurrencyTotal({
    required this.currencyCode,
    required this.totalMinor,
    required this.walletCount,
  });

  final String currencyCode;
  final int totalMinor;

  /// Non-archived wallets holding a balance row in this currency.
  final int walletCount;
}

final class WalletTransactionPage {
  const WalletTransactionPage({required this.items, required this.hasMore});

  final List<WalletTransaction> items;
  final bool hasMore;

  WalletOrderKey? get lastKey =>
      items.isEmpty ? null : WalletOrderKey.of(items.last);
}
