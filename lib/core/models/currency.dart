import '../errors/app_exception.dart';
import 'currency_palette.dart';
import 'model_validation.dart';
import 'money.dart';

final class Currency {
  Currency({
    required String code,
    required String name,
    required this.fractionDigits,
    this.symbol,
    this.isActive = true,
    this.sortOrder = 0,
    this.colorValue,
  }) : code = requireText(code, 'currency_code').toUpperCase(),
       name = requireText(name, 'currency_name') {
    if (!RegExp(r'^[A-Z]{3}$').hasMatch(this.code)) {
      throw const ValidationException(
        code: 'invalid_currency_code',
        userMessage: 'رمز العملة يجب أن يتكون من ثلاثة أحرف.',
      );
    }
    if (fractionDigits < 0 || fractionDigits > 3) {
      throw const ValidationException(
        code: 'invalid_currency',
        userMessage: 'بيانات العملة غير صالحة.',
      );
    }
  }

  final String code;
  final String name;
  final int fractionDigits;
  final String? symbol;
  final bool isActive;
  final int sortOrder;

  /// The accent the owner picked for this currency (ARGB), or null to let the
  /// app choose one from its palette. Presentation only.
  final int? colorValue;

  /// The same currency with some fields replaced. [colorValue] is replaced
  /// even when null (pass `clearColor: true` to go back to the automatic one).
  Currency copyWith({
    String? name,
    String? symbol,
    int? fractionDigits,
    bool? isActive,
    int? sortOrder,
    int? colorValue,
    bool clearColor = false,
  }) => Currency(
    code: code,
    name: name ?? this.name,
    symbol: symbol ?? this.symbol,
    fractionDigits: fractionDigits ?? this.fractionDigits,
    isActive: isActive ?? this.isActive,
    sortOrder: sortOrder ?? this.sortOrder,
    colorValue: clearColor ? null : (colorValue ?? this.colorValue),
  );
}

/// The sole conversion boundary between decimal text and minor-unit money.
///
/// A single instance is shared across the app (see `JibiApplication`) so that
/// adding, renaming, or archiving a currency is reflected everywhere without
/// restarting the app.
final class CurrencyRegistry {
  CurrencyRegistry(Iterable<Currency> currencies)
    : _currencies = {
        for (final currency in currencies) currency.code: currency,
      } {
    if (_currencies.isEmpty) {
      throw const ValidationException(
        code: 'empty_currency_registry',
        userMessage: 'يجب توفير عملة واحدة على الأقل.',
      );
    }
  }

  factory CurrencyRegistry.defaults() => CurrencyRegistry(_defaultCurrencies);

  /// The three currencies the app ships with, without decimal places; the
  /// Yemeni rial is the base. More can be added from the currency settings.
  static final List<Currency> _defaultCurrencies = <Currency>[
    Currency(
      code: 'YER',
      name: 'الريال اليمني',
      fractionDigits: 0,
      symbol: 'ر.ي',
      sortOrder: 0,
      colorValue: yerCurrencyColor,
    ),
    Currency(
      code: 'SAR',
      name: 'الريال السعودي',
      fractionDigits: 0,
      symbol: 'ر.س',
      sortOrder: 1,
      colorValue: sarCurrencyColor,
    ),
    Currency(
      code: 'USD',
      name: 'الدولار الأمريكي',
      fractionDigits: 0,
      symbol: r'$',
      sortOrder: 2,
      colorValue: usdCurrencyColor,
    ),
  ];

  final Map<String, Currency> _currencies;

  /// All known currencies, including archived ones so historical records
  /// referencing them can still be formatted and parsed.
  Iterable<Currency> get currencies => _currencies.values;

  /// Currencies selectable for new transactions, ordered for display.
  List<Currency> get activeCurrencies {
    final active =
        _currencies.values.where((currency) => currency.isActive).toList()
          ..sort((left, right) {
            final order = left.sortOrder.compareTo(right.sortOrder);
            return order != 0 ? order : left.code.compareTo(right.code);
          });
    return List<Currency>.unmodifiable(active);
  }

  /// The accent color (ARGB) of [code]: the one the owner picked, else a stable
  /// one derived from the code. Never throws for an unknown code.
  int colorValueOf(String code) =>
      _currencies[code.toUpperCase()]?.colorValue ??
      automaticCurrencyColor(code);

  /// Inserts or replaces a currency definition in the live shared registry.
  void upsert(Currency currency) {
    _currencies[currency.code] = currency;
  }

  void replaceAll(Iterable<Currency> values) {
    final validated = CurrencyRegistry(values);
    _currencies
      ..clear()
      ..addAll(validated._currencies);
  }

  /// Removes a currency definition. Callers must ensure it is unused first.
  void remove(String code) {
    _currencies.remove(code.toUpperCase());
  }

  Currency byCode(String code) {
    final currency = _currencies[code.toUpperCase()];
    if (currency == null) {
      throw const ValidationException(
        code: 'unsupported_currency',
        userMessage: 'العملة المحددة غير مدعومة.',
      );
    }
    return currency;
  }

  /// Parses a canonical ASCII decimal without rounding or floating point.
  ///
  /// A value with more decimal places than the currency supports is rejected.
  /// Leading/trailing whitespace, grouping separators, exponents, and locale
  /// decimal separators are deliberately rejected.
  Money parseAmount({required String input, required String currencyCode}) {
    final currency = byCode(currencyCode);
    final match = RegExp(r'^([+-]?)(0|[1-9]\d*)(?:\.(\d+))?$')
        .firstMatch(input);
    if (match == null) {
      throw const ValidationException(
        code: 'invalid_money_format',
        userMessage: 'أدخل مبلغاً صحيحاً دون فواصل أو تقريب.',
      );
    }

    final decimalPart = match.group(3) ?? '';
    if (decimalPart.length > currency.fractionDigits) {
      throw ValidationException(
        code: 'excess_fraction_digits',
        userMessage:
            'هذه العملة تدعم ${currency.fractionDigits} منازل عشرية فقط.',
      );
    }

    final scale = _scale(currency.fractionDigits);
    final integral = BigInt.parse(match.group(2)!);
    final fractional = decimalPart.isEmpty
        ? 0
        : int.parse(decimalPart.padRight(currency.fractionDigits, '0'));
    final exactMinor = integral * BigInt.from(scale) + BigInt.from(fractional);
    if (exactMinor > BigInt.from(9007199254740991)) {
      throw const ValidationException(
        code: 'money_out_of_range',
        userMessage: 'المبلغ أكبر من الحد المسموح.',
      );
    }
    final minor = exactMinor.toInt();
    return Money(
      amountMinor: match.group(1) == '-' ? -minor : minor,
      currencyCode: currency.code,
    );
  }

  String format(Money money) {
    final currency = byCode(money.currencyCode);
    final scale = _scale(currency.fractionDigits);
    final negative = money.amountMinor < 0;
    final magnitude = negative ? -money.amountMinor : money.amountMinor;
    final integral = magnitude ~/ scale;
    if (currency.fractionDigits == 0) {
      return '${negative ? '-' : ''}$integral';
    }
    final fraction = (magnitude % scale).toString().padLeft(
      currency.fractionDigits,
      '0',
    );
    return '${negative ? '-' : ''}$integral.$fraction';
  }

  static int _scale(int fractionDigits) {
    var result = 1;
    for (var index = 0; index < fractionDigits; index++) {
      result *= 10;
    }
    return result;
  }
}
