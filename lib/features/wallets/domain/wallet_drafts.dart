import 'dart:typed_data';

String? optionalWalletText(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// One opening balance in [WalletDraft.openings]: a currency the wallet
/// holds and how much it starts with.
final class WalletOpeningDraft {
  const WalletOpeningDraft({
    required this.currencyCode,
    this.openingMinor = 0,
  });

  final String currencyCode;
  final int openingMinor;
}

final class WalletDraft {
  const WalletDraft({
    required this.name,
    this.accountNumber,
    this.image,
    this.notes,
    this.openings = const <WalletOpeningDraft>[],
  });

  /// Convenience for the common single-currency wallet.
  factory WalletDraft.single({
    required String name,
    required String currencyCode,
    int openingMinor = 0,
    String? accountNumber,
    Uint8List? image,
    String? notes,
  }) => WalletDraft(
    name: name,
    accountNumber: accountNumber,
    image: image,
    notes: notes,
    openings: [
      WalletOpeningDraft(currencyCode: currencyCode, openingMinor: openingMinor),
    ],
  );

  final String name;
  final String? accountNumber;
  final Uint8List? image;
  final String? notes;

  /// The currencies to open the wallet with. May be empty — a wallet may be
  /// created with no currency yet and gain one automatically on its first
  /// movement.
  final List<WalletOpeningDraft> openings;
}

final class WalletDepositDraft {
  const WalletDepositDraft({
    required this.walletId,
    required this.amountMinor,
    required this.date,
    this.currencyCode,
    this.time = '00:00',
    this.notes,
  });

  final String walletId;
  final int amountMinor;

  /// Explicit currency for this movement; when null, resolved from the
  /// wallet's only currency, or the wallet controller throws
  /// `wallet_currency_required` if it holds more than one.
  final String? currencyCode;

  /// Local `YYYY-MM-DD`.
  final String date;

  /// Local `HH:mm`.
  final String time;
  final String? notes;
}

final class WalletWithdrawalDraft {
  const WalletWithdrawalDraft({
    required this.walletId,
    required this.amountMinor,
    required this.date,
    this.currencyCode,
    this.time = '00:00',
    this.notes,
  });

  final String walletId;
  final int amountMinor;
  final String? currencyCode;
  final String date;
  final String time;
  final String? notes;
}

final class WalletTransferDraft {
  const WalletTransferDraft({
    required this.fromWalletId,
    required this.toWalletId,
    required this.amountMinor,
    required this.date,
    this.fromCurrencyCode,
    this.toCurrencyCode,
    this.receivedMinor,
    this.time = '00:00',
    this.notes,
  });

  final String fromWalletId;
  final String toWalletId;

  /// The amount leaving [fromWalletId].
  final int amountMinor;

  /// Explicit source currency; resolved like [WalletDepositDraft.currencyCode]
  /// when null.
  final String? fromCurrencyCode;

  /// Explicit destination currency; resolved like
  /// [WalletDepositDraft.currencyCode] when null.
  final String? toCurrencyCode;

  /// The amount arriving in [toWalletId]. Null means "the same as
  /// [amountMinor]", which is only valid when the two currencies match; a
  /// cross-currency transfer must state it explicitly (the app suggests one
  /// from a saved rate, but never invents one silently).
  final int? receivedMinor;
  final String date;
  final String time;
  final String? notes;
}

/// Converts between two currencies inside the same wallet.
final class WalletExchangeDraft {
  const WalletExchangeDraft({
    required this.walletId,
    required this.fromCurrencyCode,
    required this.toCurrencyCode,
    required this.soldMinor,
    required this.boughtMinor,
    required this.date,
    this.time = '00:00',
    this.notes,
  });

  final String walletId;
  final String fromCurrencyCode;
  final String toCurrencyCode;

  /// The amount of [fromCurrencyCode] given up.
  final int soldMinor;

  /// The amount of [toCurrencyCode] received.
  final int boughtMinor;
  final String date;
  final String time;
  final String? notes;
}
