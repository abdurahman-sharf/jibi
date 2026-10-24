import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/core/models/models.dart';
import 'package:jibi/features/book/domain/book_labels.dart';
import 'package:jibi/features/book/domain/book_preferences.dart';

void main() {
  AppSettings settings({
    String? debit,
    String? credit,
    DateDisplayFormat format = DateDisplayFormat.yearMonthDay,
  }) => AppSettings(
    defaultCurrencyCode: 'YER',
    debitLabel: debit,
    creditLabel: credit,
    dateFormat: format,
  );

  group('BookLabels', () {
    test('standard wording keeps its hints', () {
      final labels = BookLabels.fromSettings(settings());

      expect(labels, BookLabels.standard);
      expect(labels.debitWithHint, 'مدين (لنا)');
      expect(labels.creditWithHint, 'دائن (علينا)');
      expect(labels.sideHint(BalanceSide.debit), 'لنا');
      expect(labels.sideHint(BalanceSide.settled), isEmpty);
    });

    test('custom wording drops the hints, even when only one side is renamed', () {
      final labels = BookLabels.fromSettings(settings(debit: 'مستحق لي'));

      expect(labels.debit, 'مستحق لي');
      expect(labels.credit, 'دائن');
      expect(labels.debitWithHint, 'مستحق لي');
      expect(labels.creditWithHint, 'دائن');
      expect(labels.sideHint(BalanceSide.credit), isEmpty);
      expect(labels.side(BalanceSide.debit), 'مستحق لي');
      expect(labels.entry(EntryType.debit), 'مستحق لي');
      expect(labels.entryWithHint(EntryType.credit), 'دائن');
    });

    test('are compared by value', () {
      expect(
        BookLabels.fromSettings(settings(debit: 'لي', credit: 'علي')),
        BookLabels.fromSettings(settings(debit: 'لي', credit: 'علي')),
      );
      expect(
        BookLabels.fromSettings(settings(debit: 'لي', credit: 'علي')) ==
            BookLabels.fromSettings(settings(debit: 'لي', credit: 'منا')),
        isFalse,
      );
    });
  });

  group('BookPreferences dates', () {
    BookPreferences prefs(DateDisplayFormat format) =>
        BookPreferences.fromSettings(settings(format: format));

    test('write the stored date the way the user chose', () {
      expect(prefs(DateDisplayFormat.yearMonthDay).date('2026-09-20'), '2026-09-20');
      expect(
        prefs(DateDisplayFormat.dayMonthYearSlash).date('2026-09-20'),
        '20/09/2026',
      );
      expect(
        prefs(DateDisplayFormat.dayMonthYearDash).date('2026-09-20'),
        '20-09-2026',
      );
    });

    test('leave anything that is not a date alone', () {
      final slash = prefs(DateDisplayFormat.dayMonthYearSlash);

      expect(slash.date('—'), '—');
      expect(slash.date(''), '');
      expect(slash.date('2026-09'), '2026-09');
    });

    test('a date typed as shown is turned back into the stored form', () {
      final slash = prefs(DateDisplayFormat.dayMonthYearSlash);

      expect(slash.isoFromDisplay('20/09/2026'), '2026-09-20');
      expect(slash.isoFromDisplay('5-3-2025'), '2025-03-05');
      expect(slash.isoFromDisplay(' 20/09/2026 '), '2026-09-20');
      expect(slash.isoFromDisplay('عملية'), isNull);
      expect(slash.isoFromDisplay('2026-09-20'), isNull);
      // With the stored format nothing needs converting.
      expect(
        prefs(DateDisplayFormat.yearMonthDay).isoFromDisplay('20/09/2026'),
        isNull,
      );
    });
  });

  group('BookPreferences', () {
    test('take every field from the settings', () {
      final value = BookPreferences.fromSettings(
        AppSettings(
          defaultCurrencyCode: 'YER',
          showTransactionTime: false,
          hideBalances: true,
          newestFirst: false,
          confirmBeforeDelete: false,
          defaultEntryType: EntryType.credit,
        ),
      );

      expect(value.showTime, isFalse);
      expect(value.hideBalances, isTrue);
      expect(value.newestFirst, isFalse);
      expect(value.confirmBeforeDelete, isFalse);
      expect(value.defaultEntryType, EntryType.credit);
      expect(value == BookPreferences.standard, isFalse);
      expect(BookPreferences.standard, BookPreferences.standard);
    });

    test('hide a balance only when asked to', () {
      expect(BookPreferences.standard.balance('30,100'), '30,100');
      expect(
        const BookPreferences(hideBalances: true).balance('30,100'),
        hiddenAmountText,
      );
    });
  });
}
