import 'package:flutter/services.dart';

/// Formats [minor] (an amount in minor units) with thousands separators and
/// exactly [fractionDigits] decimals, e.g. `30100`/0 -> `30,100` and
/// `485000`/2 -> `4,850.00`. The sign is never part of the result: callers
/// show it (or the debit/credit label) themselves.
String formatMinorGrouped(int minor, int fractionDigits) {
  final magnitude = minor < 0 ? -minor : minor;
  var scale = 1;
  for (var index = 0; index < fractionDigits; index++) {
    scale *= 10;
  }
  final integral = _group((magnitude ~/ scale).toString());
  if (fractionDigits == 0) {
    return integral;
  }
  final fraction = (magnitude % scale).toString().padLeft(fractionDigits, '0');
  return '$integral.$fraction';
}

String _group(String digits) {
  final buffer = StringBuffer();
  for (var index = 0; index < digits.length; index++) {
    if (index > 0 && (digits.length - index) % 3 == 0) {
      buffer.write(',');
    }
    buffer.write(digits[index]);
  }
  return buffer.toString();
}

/// Converts what the user typed (possibly with Arabic-Indic digits, an Arabic
/// decimal separator, spaces or thousands separators) into the canonical ASCII
/// decimal that `CurrencyRegistry.parseAmount` accepts.
String canonicalAmountInput(String input) {
  final buffer = StringBuffer();
  for (final rune in input.runes) {
    if (rune >= 0x0660 && rune <= 0x0669) {
      buffer.writeCharCode(rune - 0x0660 + 48);
    } else if (rune >= 0x06f0 && rune <= 0x06f9) {
      buffer.writeCharCode(rune - 0x06f0 + 48);
    } else if (rune == 0x066b) {
      buffer.write('.'); // Arabic decimal separator
    } else if (rune == 0x066c || rune == 0x2c || rune == 0x060c) {
      continue; // thousands separators: , ٬ ،
    } else if (rune == 0x20 || rune == 0xa0 || rune == 0x200e || rune == 0x200f) {
      continue;
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

/// Live thousands separators for an amount field. Allows digits (Arabic-Indic
/// too) and a single decimal separator limited to [fractionDigits] places; a
/// currency without decimals accepts no separator at all.
/// An amount typed for one currency, re-shaped for a currency with
/// [fractionDigits] decimals: the whole part stays and any decimals beyond the
/// new limit are DROPPED. Feeding "1,234.56" straight to
/// [ThousandsInputFormatter] with no decimals would glue the fraction onto the
/// whole part (123,456) — ten or a hundred times too much — so a currency
/// switch must go through this first.
String reshapeAmountText(String text, int fractionDigits) {
  final raw = canonicalAmountInput(text);
  final dot = raw.indexOf('.');
  if (dot < 0) return raw;
  if (fractionDigits <= 0) return raw.substring(0, dot);
  final decimals = raw.substring(dot + 1);
  return decimals.length <= fractionDigits
      ? raw
      : raw.substring(0, dot + 1 + fractionDigits);
}

final class ThousandsInputFormatter extends TextInputFormatter {
  ThousandsInputFormatter({required this.fractionDigits});

  final int fractionDigits;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final raw = canonicalAmountInput(newValue.text);
    final integral = StringBuffer();
    final decimals = StringBuffer();
    var sawSeparator = false;
    for (final rune in raw.runes) {
      final char = String.fromCharCode(rune);
      if (char == '.') {
        if (fractionDigits > 0 && !sawSeparator) {
          sawSeparator = true;
        }
      } else if (rune >= 48 && rune <= 57) {
        if (sawSeparator) {
          if (decimals.length < fractionDigits) {
            decimals.write(char);
          }
        } else {
          integral.write(char);
        }
      }
    }
    var integralText = integral.toString().replaceFirst(RegExp(r'^0+(?=\d)'), '');
    integralText = _group(integralText);
    final text = sawSeparator
        ? '$integralText.${decimals.toString()}'
        : integralText;

    // Keep the caret after the same number of digits/decimal point it had.
    final caretSource = newValue.selection.baseOffset.clamp(
      0,
      newValue.text.length,
    );
    var significantBefore = 0;
    for (final rune in canonicalAmountInput(
      newValue.text.substring(0, caretSource),
    ).runes) {
      if ((rune >= 48 && rune <= 57) || rune == 46) significantBefore++;
    }
    var offset = 0;
    var seen = 0;
    while (offset < text.length && seen < significantBefore) {
      if (text[offset] != ',') seen++;
      offset++;
    }
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: offset),
    );
  }
}
