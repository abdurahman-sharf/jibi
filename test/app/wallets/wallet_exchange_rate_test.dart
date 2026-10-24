import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/app/wallets/wallet_operation_forms.dart';

void main() {
  group('parseExchangeRate', () {
    test('parses a whole number', () {
      final rate = parseExchangeRate('140');
      expect(rate, isNotNull);
      expect(rate!.numerator, BigInt.from(140));
      expect(rate.scale, BigInt.one);
    });

    test('parses a decimal rate exactly, no floating point', () {
      final rate = parseExchangeRate('3.75');
      expect(rate, isNotNull);
      expect(rate!.numerator, BigInt.from(375));
      expect(rate.scale, BigInt.from(100));
    });

    test('normalizes Arabic-Indic digits and the Arabic decimal separator', () {
      final rate = parseExchangeRate('٣٫٧٥');
      expect(rate, isNotNull);
      expect(rate!.numerator, BigInt.from(375));
      expect(rate.scale, BigInt.from(100));
    });

    test('rejects empty, malformed or zero input', () {
      expect(parseExchangeRate(''), isNull);
      expect(parseExchangeRate('   '), isNull);
      expect(parseExchangeRate('abc'), isNull);
      expect(parseExchangeRate('1.2.3'), isNull);
      expect(parseExchangeRate('0'), isNull);
    });
  });

  group('roundHalfAwayFromZero', () {
    test('the owner\'s literal example: 100 SAR at 140 gives 14000 YER', () {
      // soldMinor(10000, SAR/2 digits) * rateNumerator(140) * 10^toDigits(0)
      // over 10^fromDigits(100) * rateScale(1).
      final result = roundHalfAwayFromZero(
        BigInt.from(10000) * BigInt.from(140) * BigInt.from(1),
        BigInt.from(100) * BigInt.from(1),
      );
      expect(result, 14000);
    });

    test('rounds a clean division exactly, no rounding needed', () {
      expect(roundHalfAwayFromZero(BigInt.from(10), BigInt.from(2)), 5);
    });

    test('rounds exactly half away from zero, not banker\'s rounding', () {
      // 5 / 2 = 2.5 -> 3
      expect(roundHalfAwayFromZero(BigInt.from(5), BigInt.from(2)), 3);
    });

    test('rounds down when below the halfway point', () {
      // 4 / 3 = 1.333... -> 1
      expect(roundHalfAwayFromZero(BigInt.from(4), BigInt.from(3)), 1);
    });

    test('rounds up when above the halfway point', () {
      // 5 / 3 = 1.666... -> 2
      expect(roundHalfAwayFromZero(BigInt.from(5), BigInt.from(3)), 2);
    });

    test('returns null instead of overflowing the safe integer range', () {
      final justOverSafeMax = BigInt.parse('9007199254740992');
      expect(roundHalfAwayFromZero(justOverSafeMax, BigInt.one), isNull);
    });

    test('accepts a value exactly at the safe integer ceiling', () {
      final safeMax = BigInt.parse('9007199254740991');
      expect(roundHalfAwayFromZero(safeMax, BigInt.one), 9007199254740991);
    });
  });
}
