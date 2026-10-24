import '../../../core/models/models.dart';

/// Currency-separated dashboard metrics. Values are never converted or summed
/// across currencies.
final class DashboardSummary {
  const DashboardSummary({
    required this.receivable,
    required this.payable,
    required this.cash,
  });

  /// The financial position of the book and the wallets, currency by currency:
  /// [position] is the book's per-currency debit/credit totals over the visible
  /// accounts (each transaction counts in ITS OWN currency, so an account with
  /// several currencies feeds several entries) and [walletTotals] the cash per
  /// currency. Nothing is converted or added across currencies.
  factory DashboardSummary.of({
    required List<CurrencyTotals> position,
    required List<WalletCurrencyTotal> walletTotals,
  }) => DashboardSummary(
    receivable: [
      for (final total in position)
        if (total.debitMinor > 0)
          Money(amountMinor: total.debitMinor, currencyCode: total.currencyCode),
    ],
    payable: [
      for (final total in position)
        if (total.creditMinor > 0)
          Money(amountMinor: total.creditMinor, currencyCode: total.currencyCode),
    ],
    cash: [
      for (final total in walletTotals)
        Money(amountMinor: total.totalMinor, currencyCode: total.currencyCode),
    ],
  );

  final List<Money> receivable;
  final List<Money> payable;

  /// Wallet cash on hand per currency (non-archived wallets). Combined with
  /// [receivable] and [payable] for the net financial position — a book
  /// transaction linked to a wallet moves both sides in opposite directions,
  /// so a normal linked transaction nets to zero and adds nothing here.
  final List<Money> cash;
}
