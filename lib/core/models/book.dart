import '../errors/app_exception.dart';
import 'model_validation.dart';

/// Direction of a book transaction. The database stores [dbValue].
///
/// Internally the app only ever knows DEBIT and CREDIT; the labels shown to
/// the user ("مدين"/"دائن" or a custom wording) are presentation only.
enum EntryType {
  debit('DEBIT'),
  credit('CREDIT');

  const EntryType(this.dbValue);

  final String dbValue;

  /// +1 for debit (they owe the user), -1 for credit (the user owes them).
  int get sign => this == debit ? 1 : -1;

  static EntryType fromDb(String value) => values.firstWhere(
    (type) => type.dbValue == value,
    orElse: () => throw const ValidationException(
      code: 'invalid_entry_type',
      userMessage: 'نوع العملية غير صالح.',
    ),
  );
}

/// Whether an account starts with a debit balance, a credit balance or none.
enum OpeningType {
  debit('DEBIT'),
  credit('CREDIT'),
  zero('ZERO');

  const OpeningType(this.dbValue);

  final String dbValue;

  static OpeningType fromDb(String value) => values.firstWhere(
    (type) => type.dbValue == value,
    orElse: () => throw const ValidationException(
      code: 'invalid_opening_type',
      userMessage: 'نوع الرصيد الافتتاحي غير صالح.',
    ),
  );
}

enum BookAccountStatus {
  active('active'),
  suspended('suspended'),
  archived('archived');

  const BookAccountStatus(this.dbValue);

  final String dbValue;

  static BookAccountStatus fromDb(String value) => values.firstWhere(
    (status) => status.dbValue == value,
    orElse: () => throw const ValidationException(
      code: 'invalid_account_status',
      userMessage: 'حالة الحساب غير صالحة.',
    ),
  );
}

/// How a book transaction linked to a wallet moves that wallet's balance.
///
/// Defaults to the transaction's own nature: a DEBIT means the counterparty
/// owes the user more, so cash left the wallet ([decrease]); a CREDIT means
/// cash came in ([increase]). The form seeds it that way and keeps it in step
/// with the entry type until the user touches the toggle. It stays an
/// explicit, stored value because that override is legitimate — some
/// transactions genuinely move the book and the wallet the same way.
enum WalletBalanceEffect {
  increase('INCREASE'),
  decrease('DECREASE');

  const WalletBalanceEffect(this.dbValue);

  final String dbValue;

  /// The effect a transaction of [type] has by default: a DEBIT (money went
  /// out to the counterparty) decreases the payment wallet, a CREDIT (money
  /// came in) increases it.
  static WalletBalanceEffect forEntry(EntryType type) =>
      type == EntryType.debit ? decrease : increase;

  static WalletBalanceEffect fromDb(String value) => values.firstWhere(
    (effect) => effect.dbValue == value,
    orElse: () => throw const ValidationException(
      code: 'invalid_wallet_effect',
      userMessage: 'أثر المحفظة غير صالح.',
    ),
  );
}

enum BookAttachmentKind {
  image('image'),
  transferNotice('transfer_notice'),
  receipt('receipt'),
  invoice('invoice'),
  voucher('voucher'),
  pdf('pdf'),
  document('document');

  const BookAttachmentKind(this.dbValue);

  final String dbValue;

  static BookAttachmentKind fromDb(String value) => values.firstWhere(
    (kind) => kind.dbValue == value,
    orElse: () => BookAttachmentKind.document,
  );
}

final class BookCategory {
  BookCategory({
    required String id,
    required String name,
    this.icon,
    this.description,
    this.sortOrder = 0,
    this.isActive = true,
    this.isArchived = false,
    required this.createdAt,
    required DateTime updatedAt,
  }) : id = requireId(id, 'category_id'),
       name = requireText(name, 'category_name'),
       updatedAt = requireChronologicalDates(createdAt, updatedAt);

  final String id;
  final String name;
  final String? icon;
  final String? description;
  final int sortOrder;
  final bool isActive;
  final bool isArchived;
  final DateTime createdAt;
  final DateTime updatedAt;

  BookCategory copyWith({
    String? name,
    String? Function()? icon,
    String? Function()? description,
    int? sortOrder,
    bool? isActive,
    bool? isArchived,
    required DateTime updatedAt,
  }) => BookCategory(
    id: id,
    name: name ?? this.name,
    icon: icon != null ? icon() : this.icon,
    description: description != null ? description() : this.description,
    sortOrder: sortOrder ?? this.sortOrder,
    isActive: isActive ?? this.isActive,
    isArchived: isArchived ?? this.isArchived,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

/// A person or entity in the book. It carries no currency of its own: every
/// transaction names its currency, and each currency the account uses has its
/// own opening balance ([BookAccountBalance]) and its own running balance.
final class BookAccount {
  BookAccount({
    required String id,
    required String categoryId,
    required String name,
    this.notes,
    this.phone,
    this.status = BookAccountStatus.active,
    this.sortOrder = 0,
    this.legacyAccountId,
    required this.createdAt,
    required DateTime updatedAt,
  }) : id = requireId(id, 'account_id'),
       categoryId = requireId(categoryId, 'category_id'),
       name = requireText(name, 'account_name'),
       updatedAt = requireChronologicalDates(createdAt, updatedAt);

  final String id;
  final String categoryId;
  final String name;
  final String? notes;
  final String? phone;
  final BookAccountStatus status;
  final int sortOrder;

  /// Id of the legacy `personal_accounts` row this account was migrated from.
  final String? legacyAccountId;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get acceptsTransactions => status == BookAccountStatus.active;

  BookAccount copyWith({
    String? categoryId,
    String? name,
    String? Function()? notes,
    String? Function()? phone,
    BookAccountStatus? status,
    int? sortOrder,
    required DateTime updatedAt,
  }) => BookAccount(
    id: id,
    categoryId: categoryId ?? this.categoryId,
    name: name ?? this.name,
    notes: notes != null ? notes() : this.notes,
    phone: phone != null ? phone() : this.phone,
    status: status ?? this.status,
    sortOrder: sortOrder ?? this.sortOrder,
    legacyAccountId: legacyAccountId,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

/// One currency an account uses, with its opening balance in that currency.
/// Created when an opening balance is entered for it, or automatically (at an
/// opening of zero) with the account's first transaction in it — the row is
/// what declares that the account uses the currency at all. The running balance
/// is never stored here: it is derived from the transactions, per
/// (account, currency), exactly as an account's single balance used to be.
final class BookAccountBalance {
  BookAccountBalance({
    required String accountId,
    required String currencyCode,
    this.openingMinor = 0,
    this.openingType = OpeningType.zero,
    required this.createdAt,
    required DateTime updatedAt,
  }) : accountId = requireId(accountId, 'account_id'),
       currencyCode = requireText(currencyCode, 'currency_code').toUpperCase(),
       updatedAt = requireChronologicalDates(createdAt, updatedAt) {
    if (openingMinor < 0) {
      throw const ValidationException(
        code: 'invalid_opening_balance',
        userMessage: 'الرصيد الافتتاحي لا يمكن أن يكون سالباً.',
      );
    }
    if ((openingType == OpeningType.zero) != (openingMinor == 0)) {
      throw const ValidationException(
        code: 'inconsistent_opening_balance',
        userMessage: 'حدد نوع الرصيد الافتتاحي (مدين أو دائن) لمبلغ أكبر من صفر.',
      );
    }
  }

  final String accountId;
  final String currencyCode;
  final int openingMinor;
  final OpeningType openingType;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Opening balance as a signed number: debit positive, credit negative.
  int get openingSignedMinor => switch (openingType) {
    OpeningType.debit => openingMinor,
    OpeningType.credit => -openingMinor,
    OpeningType.zero => 0,
  };

  BookAccountBalance copyWith({
    int? openingMinor,
    OpeningType? openingType,
    required DateTime updatedAt,
  }) => BookAccountBalance(
    accountId: accountId,
    currencyCode: currencyCode,
    openingMinor: openingMinor ?? this.openingMinor,
    openingType: openingType ?? this.openingType,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

final class BookAttachment {
  BookAttachment({
    required String id,
    required String transactionId,
    this.kind = BookAttachmentKind.document,
    required String fileName,
    required String mimeType,
    this.encryptedFileName,
    this.originalExtension,
    this.fileSize = 0,
    this.checksum,
    this.documentFileId,
    required this.createdAt,
  }) : id = requireId(id, 'attachment_id'),
       transactionId = requireId(transactionId, 'transaction_id'),
       fileName = requireText(fileName, 'file_name'),
       mimeType = requireText(mimeType, 'mime_type') {
    if ((encryptedFileName == null) == (documentFileId == null)) {
      throw const ValidationException(
        code: 'invalid_attachment_source',
        userMessage: 'بيانات المرفق غير صالحة.',
      );
    }
    // Backups verify every owned file against its checksum.
    if (encryptedFileName != null && (checksum == null || checksum!.isEmpty)) {
      throw const ValidationException(
        code: 'attachment_checksum_required',
        userMessage: 'بيانات المرفق غير صالحة.',
      );
    }
  }

  final String id;
  final String transactionId;
  final BookAttachmentKind kind;
  final String fileName;
  final String mimeType;

  /// Set for files owned by the book (encrypted by `SecureFileStorage`).
  final String? encryptedFileName;
  final String? originalExtension;
  final int fileSize;
  final String? checksum;

  /// Set for attachments migrated from the legacy ledger: a reference to an
  /// existing document file that the document vault still owns.
  final String? documentFileId;
  final DateTime createdAt;

  bool get isImage => mimeType.startsWith('image/');
}

final class BookTransaction {
  BookTransaction({
    required String id,
    required String number,
    required String accountId,
    required String currencyCode,
    required this.type,
    required this.amountMinor,
    required this.date,
    this.time = '00:00',
    this.details,
    this.notes,
    this.balanceAfter = 0,
    required this.createdAt,
    required DateTime updatedAt,
    this.deletedAt,
    this.attachments = const <BookAttachment>[],
    this.walletId,
    this.walletEffect,
  }) : id = requireId(id, 'transaction_id'),
       number = requireText(number, 'transaction_number'),
       accountId = requireId(accountId, 'account_id'),
       currencyCode = requireText(currencyCode, 'currency_code').toUpperCase(),
       updatedAt = requireChronologicalDates(createdAt, updatedAt) {
    if (amountMinor <= 0) {
      throw const ValidationException(
        code: 'invalid_amount',
        userMessage: 'أدخل مبلغاً أكبر من صفر.',
      );
    }
    if (!_validDate(date)) {
      throw const ValidationException(
        code: 'invalid_transaction_date',
        userMessage: 'تاريخ العملية غير صالح.',
      );
    }
    if (!RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(time)) {
      throw const ValidationException(
        code: 'invalid_transaction_time',
        userMessage: 'وقت العملية غير صالح.',
      );
    }
    if ((walletId == null) != (walletEffect == null)) {
      throw const ValidationException(
        code: 'wallet_effect_required',
        userMessage: 'حدد اتجاه أثر المحفظة (زيادة أو نقص) عند اختيارها.',
      );
    }
  }

  final String id;
  final String number;
  final String accountId;

  /// The currency of this transaction — and of its running [balanceAfter],
  /// which is kept per (account, currency). Never converted or summed with
  /// another currency.
  final String currencyCode;
  final EntryType type;
  final int amountMinor;

  /// Local calendar date, `YYYY-MM-DD`.
  final String date;

  /// Local time of day, `HH:mm`.
  final String time;
  final String? details;
  final String? notes;

  /// Running account balance right after this transaction (debit positive).
  /// A display cache: it can always be recomputed from the transactions.
  final int balanceAfter;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  final List<BookAttachment> attachments;

  /// The payment method: the wallet this transaction moved money through. The
  /// main wallet is shown to the user as «نقدًا» (see [Wallet.paymentLabel]).
  /// Every new transaction has one; only a row from before wallets were linked
  /// can still be null, and it never touches any wallet's balance. Set
  /// together with [walletEffect] — never one without the other.
  ///
  /// The old free-standing `payment_method` label (cash/bank transfer/card...)
  /// is no longer read or written; its column stays in `book_transactions`
  /// only for older databases and backups.
  final String? walletId;
  final WalletBalanceEffect? walletEffect;

  bool get isDeleted => deletedAt != null;
  int get signedMinor => type.sign * amountMinor;

  /// The local date and time as a [DateTime].
  DateTime get occurredAt {
    final parts = date.split('-');
    final clock = time.split(':');
    return DateTime(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
      int.parse(clock[0]),
      int.parse(clock[1]),
    );
  }

  BookTransaction copyWith({
    String? currencyCode,
    EntryType? type,
    int? amountMinor,
    String? date,
    String? time,
    String? Function()? details,
    String? Function()? notes,
    int? balanceAfter,
    DateTime? Function()? deletedAt,
    List<BookAttachment>? attachments,
    // walletId and walletEffect must always be passed together (both set, or
    // both cleared with `() => null`) — the constructor enforces the pair.
    String? Function()? walletId,
    WalletBalanceEffect? Function()? walletEffect,
    required DateTime updatedAt,
  }) => BookTransaction(
    id: id,
    number: number,
    accountId: accountId,
    currencyCode: currencyCode ?? this.currencyCode,
    type: type ?? this.type,
    amountMinor: amountMinor ?? this.amountMinor,
    date: date ?? this.date,
    time: time ?? this.time,
    details: details != null ? details() : this.details,
    notes: notes != null ? notes() : this.notes,
    balanceAfter: balanceAfter ?? this.balanceAfter,
    createdAt: createdAt,
    updatedAt: updatedAt,
    deletedAt: deletedAt != null ? deletedAt() : this.deletedAt,
    attachments: attachments ?? this.attachments,
    walletId: walletId != null ? walletId() : this.walletId,
    walletEffect: walletEffect != null ? walletEffect() : this.walletEffect,
  );

  static String formatDate(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  static String formatTime(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';

  /// Date and time as shown on reports and lists: `2026-09-21 14:05`.
  static String formatStamp(DateTime value) =>
      '${formatDate(value)} ${formatTime(value)}';

  static bool _validDate(String value) {
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
    if (match == null) {
      return false;
    }
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    final parsed = DateTime(year, month, day);
    return parsed.year == year && parsed.month == month && parsed.day == day;
  }
}
