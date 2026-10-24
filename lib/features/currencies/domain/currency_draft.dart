import '../../../core/errors/app_exception.dart';
import '../../../core/models/model_validation.dart';

/// Input for creating or editing a managed currency.
final class CurrencyDraft {
  const CurrencyDraft({
    required this.name,
    this.symbol,
    required this.fractionDigits,
    this.colorValue,
  });

  final String name;
  final String? symbol;
  final int fractionDigits;

  /// The accent the owner picked (ARGB); null means "automatic".
  final int? colorValue;

  void validate() {
    requireText(name, 'currency_name');
    if (fractionDigits < 0 || fractionDigits > 3) {
      throw const ValidationException(
        code: 'invalid_currency',
        userMessage: 'عدد المنازل العشرية يجب أن يكون بين 0 و3.',
      );
    }
  }
}

String requireCurrencyCode(String value) {
  final upper = value.trim().toUpperCase();
  if (!RegExp(r'^[A-Z]{3}$').hasMatch(upper)) {
    throw const ValidationException(
      code: 'invalid_currency_code',
      userMessage: 'رمز العملة يجب أن يتكون من ثلاثة أحرف إنجليزية.',
    );
  }
  return upper;
}
