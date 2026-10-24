import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/core/errors/app_exception.dart';
import 'package:jibi/core/models/models.dart';

void main() {
  AppSettings settings({String? debit, String? credit}) => AppSettings(
    defaultCurrencyCode: 'yer',
    debitLabel: debit,
    creditLabel: credit,
  );

  test('the new preferences default to the behaviour of earlier versions', () {
    final value = settings();

    expect(value.defaultCurrencyCode, 'YER');
    expect(value.dateFormat, DateDisplayFormat.yearMonthDay);
    expect(value.showTransactionTime, isTrue);
    expect(value.hideBalances, isFalse);
    expect(value.newestFirst, isTrue);
    expect(value.confirmBeforeDelete, isTrue);
    expect(value.defaultEntryType, EntryType.debit);
    expect(value.debitLabel, isNull);
    expect(value.creditLabel, isNull);
  });

  group('side wording', () {
    test('is trimmed, and blank means the standard word', () {
      final value = settings(debit: '  مستحق   لي ', credit: '   ');

      expect(value.debitLabel, 'مستحق لي');
      expect(value.creditLabel, isNull);
    });

    test('the standard word is not stored as custom wording', () {
      final value = settings(debit: 'مدين', credit: ' دائن ');

      expect(value.debitLabel, isNull);
      expect(value.creditLabel, isNull);
    });

    test('longer than 24 characters is refused', () {
      expect(
        () => settings(debit: 'أ' * (maxSideLabelLength + 1)),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.code,
            'code',
            'side_label_too_long',
          ),
        ),
      );
      expect(settings(debit: 'أ' * maxSideLabelLength).debitLabel, isNotNull);
    });

    test('the two sides may not share a word', () {
      expect(
        () => settings(debit: 'سلف', credit: 'سلف'),
        throwsA(isA<ValidationException>()),
      );
    });

    test('a custom word may not equal the other side\'s standard word', () {
      // Renaming debit to "دائن" while credit keeps "دائن" would make the two
      // sides indistinguishable.
      expect(() => settings(debit: 'دائن'), throwsA(isA<ValidationException>()));
      expect(() => settings(credit: 'مدين'), throwsA(isA<ValidationException>()));
      // Swapping both is fine.
      expect(settings(debit: 'دائن', credit: 'مدين').debitLabel, 'دائن');
    });

    test('copyWith keeps them and withSideLabels replaces or clears them', () {
      final value = settings(debit: 'لي', credit: 'علي');

      expect(value.copyWith(hideBalances: true).debitLabel, 'لي');
      expect(value.copyWith(hideBalances: true).creditLabel, 'علي');
      final cleared = value.withSideLabels();
      expect(cleared.debitLabel, isNull);
      expect(cleared.creditLabel, isNull);
      expect(value.withSideLabels(debit: 'مستحق').debitLabel, 'مستحق');
      // Everything else is carried over.
      expect(cleared.defaultCurrencyCode, 'YER');
    });
  });
}
