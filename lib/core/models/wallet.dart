import 'dart:typed_data';

import '../errors/app_exception.dart';
import 'model_validation.dart';
import 'user_profile.dart' show maxProfileImageBytes;

/// What the user sees for the main wallet as a payment method.
const String cashPaymentLabel = 'نقدًا';

enum WalletStatus {
  active('active'),
  archived('archived');

  const WalletStatus(this.dbValue);

  final String dbValue;

  static WalletStatus fromDb(String value) => values.firstWhere(
    (status) => status.dbValue == value,
    orElse: () => throw const ValidationException(
      code: 'invalid_wallet_status',
      userMessage: 'حالة المحفظة غير صالحة.',
    ),
  );
}

/// A place money is kept — a cash box, a bank account, anything the user
/// names. Can hold several currencies at once; see [WalletBalance]. Exactly
/// one wallet can be [isMain] at a time (the seeded «الصندوق الرئيسي»); the
/// app never requires one to exist.
final class Wallet {
  Wallet({
    required String id,
    required String name,
    this.isMain = false,
    this.accountNumber,
    this.image,
    this.notes,
    this.status = WalletStatus.active,
    this.sortOrder = 0,
    required this.createdAt,
    required DateTime updatedAt,
  }) : id = requireId(id, 'wallet_id'),
       name = requireText(name, 'wallet_name'),
       updatedAt = requireChronologicalDates(createdAt, updatedAt) {
    final picture = image;
    if (picture != null && picture.length > maxProfileImageBytes) {
      throw const ValidationException(
        code: 'wallet_image_too_large',
        userMessage: 'الصورة كبيرة جداً. اختر صورة أصغر.',
      );
    }
  }

  final String id;
  final String name;
  final bool isMain;

  /// An account number or IBAN, if the user wants to record one — optional
  /// for every wallet, not just a bank account.
  final String? accountNumber;
  final Uint8List? image;
  final String? notes;
  final WalletStatus status;
  final int sortOrder;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// How this wallet is shown wherever a transaction's payment method appears
  /// (form, details, log, statement, filters, reports): the main wallet is
  /// plain «نقدًا», any other wallet keeps the name the user gave it.
  String get paymentLabel => isMain ? cashPaymentLabel : name;

  Wallet copyWith({
    String? name,
    bool? isMain,
    String? Function()? accountNumber,
    Uint8List? Function()? image,
    String? Function()? notes,
    WalletStatus? status,
    int? sortOrder,
    required DateTime updatedAt,
  }) => Wallet(
    id: id,
    name: name ?? this.name,
    isMain: isMain ?? this.isMain,
    accountNumber: accountNumber != null ? accountNumber() : this.accountNumber,
    image: image != null ? image() : this.image,
    notes: notes != null ? notes() : this.notes,
    status: status ?? this.status,
    sortOrder: sortOrder ?? this.sortOrder,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

/// One currency a [Wallet] holds. Created automatically on the wallet's first
/// movement in a currency it did not hold yet (at opening zero), or up front
/// when the user sets an opening balance for it in the wallet form. Removing
/// one (once it has no movements) is the only way a wallet stops holding a
/// currency.
final class WalletBalance {
  WalletBalance({
    required String walletId,
    required String currencyCode,
    this.openingMinor = 0,
    this.sortOrder = 0,
    required this.createdAt,
    required DateTime updatedAt,
  }) : walletId = requireId(walletId, 'wallet_id'),
       currencyCode = requireText(currencyCode, 'currency_code').toUpperCase(),
       updatedAt = requireChronologicalDates(createdAt, updatedAt) {
    if (openingMinor < 0) {
      throw const ValidationException(
        code: 'invalid_opening_balance',
        userMessage: 'الرصيد الافتتاحي لا يمكن أن يكون سالباً.',
      );
    }
  }

  final String walletId;
  final String currencyCode;
  final int openingMinor;
  final int sortOrder;
  final DateTime createdAt;
  final DateTime updatedAt;

  WalletBalance copyWith({
    int? openingMinor,
    int? sortOrder,
    required DateTime updatedAt,
  }) => WalletBalance(
    walletId: walletId,
    currencyCode: currencyCode,
    openingMinor: openingMinor ?? this.openingMinor,
    sortOrder: sortOrder ?? this.sortOrder,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

/// What kind of movement a [WalletTransaction] records.
enum WalletTransactionType {
  deposit('deposit'),
  withdrawal('withdrawal'),
  transfer('transfer'),

  /// Converts between two currencies inside the same wallet (two legs, one
  /// [WalletTransaction.legGroupId], same wallet, different currencies).
  exchange('exchange'),

  /// Created automatically when a book transaction is paid through this
  /// wallet.
  linked('linked');

  const WalletTransactionType(this.dbValue);

  final String dbValue;

  static WalletTransactionType fromDb(String value) => values.firstWhere(
    (type) => type.dbValue == value,
    orElse: () => throw const ValidationException(
      code: 'invalid_wallet_transaction_type',
      userMessage: 'نوع حركة المحفظة غير صالح.',
    ),
  );
}

/// Which way a [WalletTransaction] moves its wallet's balance.
enum WalletDirection {
  incoming('IN'),
  outgoing('OUT');

  const WalletDirection(this.dbValue);

  final String dbValue;

  /// +1 for money coming in, -1 for money going out.
  int get sign => this == incoming ? 1 : -1;

  static WalletDirection fromDb(String value) => values.firstWhere(
    (direction) => direction.dbValue == value,
    orElse: () => throw const ValidationException(
      code: 'invalid_wallet_direction',
      userMessage: 'اتجاه حركة المحفظة غير صالح.',
    ),
  );
}

final class WalletTransaction {
  WalletTransaction({
    required String id,
    required String number,
    required String walletId,
    required String currencyCode,
    required this.type,
    required this.direction,
    required this.amountMinor,
    this.balanceAfter = 0,
    this.legGroupId,
    this.linkedBookTransactionId,
    required this.date,
    this.time = '00:00',
    this.notes,
    required this.createdAt,
    required DateTime updatedAt,
    this.deletedAt,
  }) : id = requireId(id, 'wallet_transaction_id'),
       number = requireText(number, 'wallet_transaction_number'),
       walletId = requireId(walletId, 'wallet_id'),
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
        userMessage: 'تاريخ الحركة غير صالح.',
      );
    }
    if (!RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(time)) {
      throw const ValidationException(
        code: 'invalid_transaction_time',
        userMessage: 'وقت الحركة غير صالح.',
      );
    }
    final isLeg =
        type == WalletTransactionType.transfer ||
        type == WalletTransactionType.exchange;
    if (isLeg != (legGroupId != null)) {
      throw const ValidationException(
        code: 'invalid_transfer_group',
        userMessage: 'بيانات التحويل غير صالحة.',
      );
    }
    if ((type == WalletTransactionType.linked) !=
        (linkedBookTransactionId != null)) {
      throw const ValidationException(
        code: 'invalid_wallet_link',
        userMessage: 'ربط المحفظة بالعملية غير صالح.',
      );
    }
  }

  final String id;
  final String number;
  final String walletId;
  final String currencyCode;
  final WalletTransactionType type;
  final WalletDirection direction;
  final int amountMinor;

  /// Running balance of this wallet's [currencyCode] right after this row (a
  /// display cache).
  final int balanceAfter;

  /// Shared by the two legs of a [WalletTransactionType.transfer] or a
  /// [WalletTransactionType.exchange].
  final String? legGroupId;

  /// Set only for [WalletTransactionType.linked] rows.
  final String? linkedBookTransactionId;

  /// Local calendar date, `YYYY-MM-DD`.
  final String date;

  /// Local time of day, `HH:mm`.
  final String time;
  final String? notes;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;
  int get signedMinor => direction.sign * amountMinor;

  WalletTransaction copyWith({
    int? amountMinor,
    int? balanceAfter,
    String? date,
    String? time,
    String? Function()? notes,
    DateTime? Function()? deletedAt,
    required DateTime updatedAt,
  }) => WalletTransaction(
    id: id,
    number: number,
    walletId: walletId,
    currencyCode: currencyCode,
    type: type,
    direction: direction,
    amountMinor: amountMinor ?? this.amountMinor,
    balanceAfter: balanceAfter ?? this.balanceAfter,
    legGroupId: legGroupId,
    linkedBookTransactionId: linkedBookTransactionId,
    date: date ?? this.date,
    time: time ?? this.time,
    notes: notes != null ? notes() : this.notes,
    createdAt: createdAt,
    updatedAt: updatedAt,
    deletedAt: deletedAt != null ? deletedAt() : this.deletedAt,
  );

  static String formatDate(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  static String formatTime(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';

  static bool _validDate(String value) {
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
    if (match == null) return false;
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    final parsed = DateTime(year, month, day);
    return parsed.year == year && parsed.month == month && parsed.day == day;
  }
}
