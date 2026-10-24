import 'book.dart';

/// Which side of zero a balance is on. Debit means the counter-party owes the
/// user ("مدين (لنا)"), credit means the user owes them ("دائن (علينا)").
enum BalanceSide { debit, credit, settled }

BalanceSide balanceSideOf(int netMinor) => netMinor > 0
    ? BalanceSide.debit
    : netMinor < 0
    ? BalanceSide.credit
    : BalanceSide.settled;

/// Total order of an account's transactions. The same key orders pages,
/// running balances and the migration, so all of them always agree.
final class BookOrderKey implements Comparable<BookOrderKey> {
  const BookOrderKey({
    required this.date,
    required this.time,
    required this.createdAtMs,
    required this.id,
  });

  factory BookOrderKey.of(BookTransaction transaction) => BookOrderKey(
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
  int compareTo(BookOrderKey other) {
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
      other is BookOrderKey && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(date, time, createdAtMs, id);
}

/// Search and filter options for one account's transactions.
final class BookTransactionFilter {
  const BookTransactionFilter({
    this.type,
    this.fromDate,
    this.toDate,
    this.minAmountMinor,
    this.maxAmountMinor,
    this.withAttachments = false,
    this.text,
    this.textAmountsMinor,
    this.walletId,
    this.currencyCode,
  });

  static const none = BookTransactionFilter();

  final EntryType? type;

  /// Inclusive `YYYY-MM-DD` bounds.
  final String? fromDate;
  final String? toDate;
  final int? minAmountMinor;
  final int? maxAmountMinor;
  final bool withAttachments;

  /// Matches details, notes, the transaction number and the date.
  final String? text;

  /// When the text is a number: also matches a transaction with exactly that
  /// amount IN ITS OWN CURRENCY. The same digits are a different number of minor
  /// units in currencies with different decimals (100 is 100 in YER and 10000
  /// in SAR), so the amount is given per currency code.
  final Map<String, int>? textAmountsMinor;

  /// The payment method: one specific wallet (the main wallet is «نقدًا») the
  /// transaction was paid through.
  final String? walletId;

  /// One currency of the account; null means every currency. The account's
  /// balances are per currency, so a filtered list, its count and its totals
  /// only ever describe the one currency asked for.
  final String? currencyCode;

  bool get isEmpty =>
      type == null &&
      fromDate == null &&
      toDate == null &&
      minAmountMinor == null &&
      maxAmountMinor == null &&
      !withAttachments &&
      walletId == null &&
      currencyCode == null &&
      (text == null || text!.trim().isEmpty);

  BookTransactionFilter copyWith({
    EntryType? Function()? type,
    String? Function()? fromDate,
    String? Function()? toDate,
    int? Function()? minAmountMinor,
    int? Function()? maxAmountMinor,
    bool? withAttachments,
    String? Function()? text,
    Map<String, int>? Function()? textAmountsMinor,
    String? Function()? walletId,
    String? Function()? currencyCode,
  }) => BookTransactionFilter(
    type: type != null ? type() : this.type,
    fromDate: fromDate != null ? fromDate() : this.fromDate,
    toDate: toDate != null ? toDate() : this.toDate,
    minAmountMinor: minAmountMinor != null
        ? minAmountMinor()
        : this.minAmountMinor,
    maxAmountMinor: maxAmountMinor != null
        ? maxAmountMinor()
        : this.maxAmountMinor,
    withAttachments: withAttachments ?? this.withAttachments,
    text: text != null ? text() : this.text,
    textAmountsMinor: textAmountsMinor != null
        ? textAmountsMinor()
        : this.textAmountsMinor,
    walletId: walletId != null ? walletId() : this.walletId,
    currencyCode: currencyCode != null ? currencyCode() : this.currencyCode,
  );
}

/// One account's position in ONE currency: its opening balance in that
/// currency plus every live debit and credit in that currency. Two currencies
/// are never added together, so an account has one of these per currency it
/// uses — there is no total across them.
final class AccountCurrencyTotals {
  const AccountCurrencyTotals({
    required this.currencyCode,
    this.openingMinor = 0,
    this.openingType = OpeningType.zero,
    this.debitMinor = 0,
    this.creditMinor = 0,
    this.transactionCount = 0,
  });

  final String currencyCode;

  /// The opening balance in this currency, on its own side.
  final int openingMinor;
  final OpeningType openingType;

  /// Includes the opening balance when it is a debit.
  final int debitMinor;

  /// Includes the opening balance when it is a credit.
  final int creditMinor;

  /// Live transactions in this currency.
  final int transactionCount;

  int get netMinor => debitMinor - creditMinor;
  BalanceSide get side => balanceSideOf(netMinor);

  /// A currency an account "uses" is one with an opening balance or at least
  /// one live transaction; only those are ever shown.
  bool get isUsed => openingMinor > 0 || transactionCount > 0;
}

final class AccountSummary {
  const AccountSummary({required this.account, required this.currencies});

  final BookAccount account;

  /// One entry per currency the account uses (see
  /// [AccountCurrencyTotals.isUsed]), sorted by currency code. Deleted rows are
  /// excluded; the opening balance is counted on its own side.
  final List<AccountCurrencyTotals> currencies;

  /// Live transactions across every currency (a count, not an amount).
  int get transactionCount =>
      currencies.fold(0, (sum, line) => sum + line.transactionCount);

  /// The position in [code], or null when the account does not use it.
  AccountCurrencyTotals? totalsOf(String code) {
    final upper = code.toUpperCase();
    for (final line in currencies) {
      if (line.currencyCode == upper) return line;
    }
    return null;
  }

  /// The currencies the account uses, sorted.
  List<String> get currencyCodes => [
    for (final line in currencies) line.currencyCode,
  ];
}

final class CurrencyTotals {
  const CurrencyTotals({
    required this.currencyCode,
    required this.debitMinor,
    required this.creditMinor,
    required this.accountCount,
  });

  final String currencyCode;
  final int debitMinor;
  final int creditMinor;
  final int accountCount;

  int get netMinor => debitMinor - creditMinor;
  BalanceSide get side => balanceSideOf(netMinor);
}

final class CategorySummary {
  const CategorySummary({
    required this.category,
    required this.accountCount,
    required this.totals,
  });

  final BookCategory category;

  /// Accounts that are not archived.
  final int accountCount;

  /// One entry per currency, sorted by currency code.
  final List<CurrencyTotals> totals;
}

final class TransactionPage {
  const TransactionPage({required this.items, required this.hasMore});

  final List<BookTransaction> items;
  final bool hasMore;

  BookOrderKey? get lastKey =>
      items.isEmpty ? null : BookOrderKey.of(items.last);
}

/// What an audit-log entry is about.
enum BookAuditEntity {
  transaction('transaction'),
  account('account'),
  category('category'),
  wallet('wallet');

  const BookAuditEntity(this.dbValue);

  final String dbValue;

  static BookAuditEntity? fromDb(String value) {
    for (final entity in values) {
      if (entity.dbValue == value) return entity;
    }
    return null;
  }
}

/// One line of the audit log (سجل التعديلات), with the names it refers to
/// resolved so it can be read without opening anything else.
final class BookAuditEntry {
  const BookAuditEntry({
    required this.id,
    required this.sequence,
    required this.entity,
    required this.entityId,
    required this.action,
    required this.createdAt,
    this.details,
    this.accountId,
    this.accountName,
    this.currencyCode,
    this.categoryName,
    this.transactionNumber,
  });

  final String id;

  /// Insertion order: entries written within the same millisecond keep the
  /// order they were written in.
  final int sequence;
  final BookAuditEntity entity;
  final String entityId;

  /// `created`, `amount_changed`, `deleted`... (see the text builder).
  final String action;
  final DateTime createdAt;

  /// What the writer recorded, such as `30000->20000` or a file name.
  final String? details;

  /// The account the entry belongs to (the account itself, or the account of
  /// the transaction) when it still exists.
  final String? accountId;
  final String? accountName;
  final String? currencyCode;
  final String? categoryName;
  final String? transactionNumber;
}

/// One page of the audit log, newest first.
final class BookAuditPage {
  const BookAuditPage({required this.items, required this.hasMore});

  final List<BookAuditEntry> items;
  final bool hasMore;
}
