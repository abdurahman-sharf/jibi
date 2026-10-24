import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/shared/formatting/money_format.dart';

TextEditingValue _type(
  ThousandsInputFormatter formatter,
  String text, {
  int? caret,
  String previous = '',
}) => formatter.formatEditUpdate(
  TextEditingValue(text: previous),
  TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: caret ?? text.length),
  ),
);

void main() {
  group('formatMinorGrouped', () {
    test('groups thousands and keeps the currency decimals', () {
      expect(formatMinorGrouped(30100, 0), '30,100');
      expect(formatMinorGrouped(0, 0), '0');
      expect(formatMinorGrouped(999, 0), '999');
      expect(formatMinorGrouped(1000, 0), '1,000');
      expect(formatMinorGrouped(485000, 2), '4,850.00');
      expect(formatMinorGrouped(5, 2), '0.05');
      expect(formatMinorGrouped(1234567890, 3), '1,234,567.890');
    });

    test('never shows a sign', () {
      expect(formatMinorGrouped(-30100, 0), '30,100');
    });
  });

  group('canonicalAmountInput', () {
    test('turns Arabic digits, separators and spaces into ASCII decimals', () {
      expect(canonicalAmountInput('٣٠٬١٠٠'), '30100');
      expect(canonicalAmountInput('١٢٣٫٥٠'), '123.50');
      expect(canonicalAmountInput('1,234.5'), '1234.5');
      expect(canonicalAmountInput(' 12 000 '), '12000');
    });
  });

  group('ThousandsInputFormatter', () {
    test('adds separators while typing', () {
      final f = ThousandsInputFormatter(fractionDigits: 0);
      expect(_type(f, '30100').text, '30,100');
      expect(_type(f, '1234567').text, '1,234,567');
      expect(_type(f, '999').text, '999');
    });

    test('accepts Arabic-Indic digits', () {
      final f = ThousandsInputFormatter(fractionDigits: 0);
      expect(_type(f, '٣٠١٠٠').text, '30,100');
    });

    test('limits decimals to the currency and drops extras', () {
      final f = ThousandsInputFormatter(fractionDigits: 2);
      expect(_type(f, '4850.129').text, '4,850.12');
      expect(_type(f, '4850.').text, '4,850.');
      expect(_type(f, '1.2.3').text, '1.23');
    });

    test('a currency without decimals accepts no separator', () {
      final f = ThousandsInputFormatter(fractionDigits: 0);
      expect(_type(f, '12.5').text, '125');
    });

    test('reshaping an amount for another currency drops decimals, never '
        'merges them into the whole part', () {
      // SAR (2 decimals) -> YER (none): 1,234.56 is 1,234, not 123,456.
      expect(reshapeAmountText('1,234.56', 0), '1234');
      expect(reshapeAmountText('1,234.56', 3), '1234.56');
      expect(reshapeAmountText('1,234.567', 2), '1234.56');
      expect(reshapeAmountText('12.', 0), '12');
      expect(reshapeAmountText('12', 2), '12');
      expect(reshapeAmountText('', 2), '');
      final yer = ThousandsInputFormatter(fractionDigits: 0);
      expect(_type(yer, reshapeAmountText('1,234.56', 0)).text, '1,234');
    });

    test('strips useless leading zeros but keeps a single zero', () {
      final f = ThousandsInputFormatter(fractionDigits: 2);
      expect(_type(f, '000').text, '0');
      expect(_type(f, '007').text, '7');
      expect(_type(f, '0.5').text, '0.5');
    });

    test('ignores letters and symbols', () {
      final f = ThousandsInputFormatter(fractionDigits: 2);
      expect(_type(f, 'a1b2-3').text, '123');
    });

    test('keeps the caret after the same digit', () {
      final f = ThousandsInputFormatter(fractionDigits: 0);
      // A "9" typed after "12" in "1,234": the caret must stay right after it.
      final result = _type(f, '12934', caret: 3, previous: '1,234');
      expect(result.text, '12,934');
      expect(result.selection.baseOffset, 4); // "12,9|34"
    });

    test('parses back to the typed value', () {
      final f = ThousandsInputFormatter(fractionDigits: 2);
      expect(canonicalAmountInput(_type(f, '4850.5').text), '4850.5');
    });
  });
}
