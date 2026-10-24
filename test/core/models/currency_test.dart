import 'package:flutter_test/flutter_test.dart';
import 'package:jibi/core/errors/app_exception.dart';
import 'package:jibi/core/models/currency.dart';
import 'package:jibi/core/models/currency_palette.dart';
import 'package:jibi/core/models/money.dart';
import '../../support/test_currencies.dart';

void main() {
  final registry = testCurrencyRegistry();

  group('CurrencyRegistry.parseAmount', () {
    test('converts two-decimal currencies to minor units exactly', () {
      expect(
        registry.parseAmount(input: '10.50', currencyCode: 'SAR'),
        Money(amountMinor: 1050, currencyCode: 'SAR'),
      );
    });

    test('converts three-decimal currencies to minor units exactly', () {
      expect(
        registry.parseAmount(input: '1.234', currencyCode: 'KWD'),
        Money(amountMinor: 1234, currencyCode: 'KWD'),
      );
    });

    test('pads omitted fractional digits without floating point', () {
      expect(
        registry.parseAmount(input: '10.5', currencyCode: 'SAR'),
        Money(amountMinor: 1050, currencyCode: 'SAR'),
      );
    });

    test('rejects precision beyond the selected currency', () {
      expect(
        () => registry.parseAmount(input: '1.2345', currencyCode: 'KWD'),
        throwsA(isA<ValidationException>()),
      );
    });

    test('rejects non-canonical decimal forms', () {
      for (final input in <String>[' 10.50', '1,000', '1e3', '.50', '01.00']) {
        expect(
          () => registry.parseAmount(input: input, currencyCode: 'SAR'),
          throwsA(isA<ValidationException>()),
        );
      }
    });
  });

  group('shipped defaults', () {
    final shipped = CurrencyRegistry.defaults();

    test('three currencies without decimals, the Yemeni rial first', () {
      expect(shipped.activeCurrencies.map((c) => c.code), ['YER', 'SAR', 'USD']);
      expect(shipped.activeCurrencies.map((c) => c.fractionDigits), [0, 0, 0]);
      expect(shipped.byCode('YER').name, 'الريال اليمني');
      expect(shipped.byCode('SAR').name, 'الريال السعودي');
      expect(shipped.byCode('USD').name, 'الدولار الأمريكي');
      expect(
        shipped.format(Money(amountMinor: 1500, currencyCode: 'SAR')),
        '1500',
      );
    });

    test('each has its own color, and any code has a stable fallback', () {
      expect(shipped.colorValueOf('YER'), yerCurrencyColor);
      expect(shipped.colorValueOf('SAR'), sarCurrencyColor);
      expect(shipped.colorValueOf('USD'), usdCurrencyColor);
      expect({
        yerCurrencyColor,
        sarCurrencyColor,
        usdCurrencyColor,
      }, hasLength(3));
      // An unknown or uncolored code still gets a palette color, the same one
      // every time.
      expect(shipped.colorValueOf('EGP'), automaticCurrencyColor('EGP'));
      expect(currencyPalette, contains(automaticCurrencyColor('EGP')));
      expect(automaticCurrencyColor('egp'), automaticCurrencyColor('EGP'));
    });

    test('a new currency takes the first palette color nobody wears', () {
      expect(
        nextFreeCurrencyColor(const [
          yerCurrencyColor,
          sarCurrencyColor,
          usdCurrencyColor,
        ], 'EGP'),
        currencyPalette[3],
      );
      expect(nextFreeCurrencyColor(currencyPalette, 'EGP'), isNotNull);
      expect(
        nextFreeCurrencyColor(<int?>[null, currencyPalette.first], 'EGP'),
        currencyPalette[1],
      );
    });

    test('copyWith keeps the color unless told to clear it', () {
      final currency = shipped.byCode('SAR');
      expect(currency.copyWith(isActive: false).colorValue, sarCurrencyColor);
      expect(currency.copyWith(sortOrder: 5).sortOrder, 5);
      expect(currency.copyWith(clearColor: true).colorValue, isNull);
    });
  });
}
