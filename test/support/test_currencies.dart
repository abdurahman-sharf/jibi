import 'package:jibi/core/models/currency.dart';

/// The currency set most tests were written against: Saudi rial and dollar at
/// two places, the Gulf dinars at three, the Yemeni rial at none.
///
/// The app itself ships with three currencies at no decimals
/// ([CurrencyRegistry.defaults]); tests that exercise money formatting or
/// several decimal rules use this explicit list instead, so a change to the
/// shipped defaults never silently changes what they assert.
CurrencyRegistry testCurrencyRegistry() => CurrencyRegistry(<Currency>[
  Currency(code: 'SAR', name: 'ريال سعودي', fractionDigits: 2, symbol: 'ر.س'),
  Currency(code: 'USD', name: 'دولار أمريكي', fractionDigits: 2, symbol: r'$'),
  Currency(code: 'EUR', name: 'يورو', fractionDigits: 2, symbol: '€'),
  Currency(code: 'AED', name: 'درهم إماراتي', fractionDigits: 2, symbol: 'د.إ'),
  Currency(code: 'KWD', name: 'دينار كويتي', fractionDigits: 3, symbol: 'د.ك'),
  Currency(code: 'BHD', name: 'دينار بحريني', fractionDigits: 3, symbol: 'د.ب'),
  Currency(code: 'OMR', name: 'ريال عماني', fractionDigits: 3, symbol: 'ر.ع'),
  Currency(code: 'QAR', name: 'ريال قطري', fractionDigits: 2, symbol: 'ر.ق'),
  Currency(code: 'GBP', name: 'جنيه إسترليني', fractionDigits: 2, symbol: '£'),
  Currency(code: 'YER', name: 'ريال يمني', fractionDigits: 0, symbol: 'ر.ي'),
]);
