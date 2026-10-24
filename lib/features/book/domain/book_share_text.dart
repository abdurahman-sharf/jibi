import '../../../core/models/models.dart';

/// `2024-12-13` -> `13/12/2024` (the format of the shared text).
String bookShareDate(String isoDate) {
  final parts = isoDate.split('-');
  return parts.length == 3 ? '${parts[2]}/${parts[1]}/${parts[0]}' : isoDate;
}

/// The plain text sent when a single transaction is shared, for example:
///
/// ```
/// الحساب: علي أخي
/// رقم العملية: TX-000001
/// التاريخ: 13/12/2024
/// العملية: مدين
/// المبلغ: 30,000 YER
/// التفاصيل: يوم موت أبي علي
/// الرصيد: 30,000 YER (مدين)
/// ```
String bookTransactionShareText({
  required String accountName,
  required BookTransaction transaction,
  required String currencyCode,
  required String typeLabel,
  required String amountText,
  required String balanceText,
  required String balanceSideLabel,
  String? paymentLabel,
}) {
  final lines = <String>[
    'الحساب: $accountName',
    'رقم العملية: ${transaction.number}',
    'التاريخ: ${bookShareDate(transaction.date)}',
    'العملية: $typeLabel',
    'المبلغ: $amountText $currencyCode',
    if (transaction.details?.isNotEmpty ?? false)
      'التفاصيل: ${transaction.details}',
    if (transaction.notes?.isNotEmpty ?? false)
      'ملاحظات: ${transaction.notes}',
    if (paymentLabel != null) 'وسيلة الدفع: $paymentLabel',
    'الرصيد: $balanceText $currencyCode ($balanceSideLabel)',
  ];
  return lines.join('\n');
}
