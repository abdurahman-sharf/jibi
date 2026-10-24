import '../../../core/models/models.dart';

String? optionalBookText(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

final class BookCategoryDraft {
  const BookCategoryDraft({required this.name, this.icon, this.description});

  final String name;
  final String? icon;
  final String? description;
}

/// The opening balance of ONE currency of an account: [openingMinor] on the
/// [openingType] side, in [currencyCode].
final class BookAccountOpeningDraft {
  const BookAccountOpeningDraft({
    required this.currencyCode,
    this.openingMinor = 0,
    this.openingType = OpeningType.zero,
  });

  final String currencyCode;
  final int openingMinor;
  final OpeningType openingType;
}

/// A person or entity. It has no currency: each transaction names its own, and
/// each currency has its own opening balance.
final class BookAccountDraft {
  const BookAccountDraft({
    required this.categoryId,
    required this.name,
    this.openings,
    this.notes,
    this.phone,
  });

  /// Convenience for an account opened with one currency (the common case in
  /// tests and simple flows).
  factory BookAccountDraft.single({
    required String categoryId,
    required String name,
    required String currencyCode,
    int openingMinor = 0,
    OpeningType openingType = OpeningType.zero,
    String? notes,
    String? phone,
  }) => BookAccountDraft(
    categoryId: categoryId,
    name: name,
    openings: [
      BookAccountOpeningDraft(
        currencyCode: currencyCode,
        openingMinor: openingMinor,
        openingType: openingType,
      ),
    ],
    notes: notes,
    phone: phone,
  );

  final String categoryId;
  final String name;

  /// The opening balances, one per currency. On create, null means none (every
  /// currency then starts at zero the first time it is used). On update, null
  /// leaves the existing openings alone; a list REPLACES them — a currency left
  /// out has its opening reset to zero (its row stays while it has
  /// transactions).
  final List<BookAccountOpeningDraft>? openings;
  final String? notes;
  final String? phone;
}

final class BookTransactionDraft {
  const BookTransactionDraft({
    required this.accountId,
    required this.currencyCode,
    required this.type,
    required this.amountMinor,
    required this.date,
    this.time = '00:00',
    this.details,
    this.notes,
    this.walletId,
    this.walletEffect,
  });

  final String accountId;

  /// The currency of this transaction; must be an active currency. Balances,
  /// totals and the wallet movement of the payment method all stay in it.
  final String currencyCode;
  final EntryType type;
  final int amountMinor;

  /// Local `YYYY-MM-DD`.
  final String date;

  /// Local `HH:mm`.
  final String time;
  final String? details;
  final String? notes;

  /// The payment method: the wallet this transaction moves money through (the
  /// main wallet is «نقدًا»). Required for a new transaction; only editing a
  /// row from before wallets were linked may leave it null.
  final String? walletId;

  /// Whether the wallet's balance goes up or down. Defaults to what the type
  /// implies (DEBIT decreases, CREDIT increases — see
  /// [WalletBalanceEffect.forEntry]); ignored when [walletId] is null.
  final WalletBalanceEffect? walletEffect;
}
