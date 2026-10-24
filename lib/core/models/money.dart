import 'model_validation.dart';

/// An integer monetary amount paired with its ISO 4217 or custom currency.
///
/// Amounts are always minor units. This type intentionally has no `double` or
/// `num` constructor to prevent floating-point values entering the domain.
final class Money {
  Money({required this.amountMinor, required String currencyCode})
    : currencyCode = requireText(currencyCode, 'currency_code').toUpperCase();

  final int amountMinor;
  final String currencyCode;

  @override
  bool operator ==(Object other) =>
      other is Money &&
      other.amountMinor == amountMinor &&
      other.currencyCode == currencyCode;

  @override
  int get hashCode => Object.hash(amountMinor, currencyCode);

  @override
  String toString() => 'Money($amountMinor $currencyCode)';
}
