import '../../../core/models/models.dart';
import 'book_labels.dart';

/// How the accounts book is shown and entered, taken from the settings: the
/// wording of the two sides, how dates are written, whether the time is shown,
/// whether balances are hidden, the default order of transactions, whether a
/// deletion asks first and which side a new transaction starts on.
/// Presentation only; nothing stored depends on it.
final class BookPreferences {
  const BookPreferences({
    this.labels = BookLabels.standard,
    this.dateFormat = DateDisplayFormat.yearMonthDay,
    this.showTime = true,
    this.hideBalances = false,
    this.newestFirst = true,
    this.confirmBeforeDelete = true,
    this.defaultEntryType = EntryType.debit,
  });

  static const standard = BookPreferences();

  factory BookPreferences.fromSettings(AppSettings settings) => BookPreferences(
    labels: BookLabels.fromSettings(settings),
    dateFormat: settings.dateFormat,
    showTime: settings.showTransactionTime,
    hideBalances: settings.hideBalances,
    newestFirst: settings.newestFirst,
    confirmBeforeDelete: settings.confirmBeforeDelete,
    defaultEntryType: settings.defaultEntryType,
  );

  final BookLabels labels;
  final DateDisplayFormat dateFormat;
  final bool showTime;
  final bool hideBalances;
  final bool newestFirst;
  final bool confirmBeforeDelete;
  final EntryType defaultEntryType;

  /// Writes a stored date (`YYYY-MM-DD`) the way the user chose. Anything that
  /// is not such a date is returned unchanged.
  String date(String isoDate) {
    final parts = isoDate.split('-');
    if (parts.length != 3 || parts.any((part) => part.isEmpty)) {
      return isoDate;
    }
    return switch (dateFormat) {
      DateDisplayFormat.yearMonthDay => isoDate,
      DateDisplayFormat.dayMonthYearSlash =>
        '${parts[2]}/${parts[1]}/${parts[0]}',
      DateDisplayFormat.dayMonthYearDash =>
        '${parts[2]}-${parts[1]}-${parts[0]}',
    };
  }

  /// A date typed the way it is shown ("20/09/2026") in the stored form
  /// ("2026-09-20"), or null when [text] is not such a date. Lets the search
  /// find a transaction by the date the user sees.
  String? isoFromDisplay(String text) {
    if (dateFormat == DateDisplayFormat.yearMonthDay) return null;
    final match = RegExp(
      r'^(\d{1,2})[/-](\d{1,2})[/-](\d{4})$',
    ).firstMatch(text.trim());
    if (match == null) return null;
    final day = match.group(1)!.padLeft(2, '0');
    final month = match.group(2)!.padLeft(2, '0');
    return '${match.group(3)}-$month-$day';
  }

  /// [text] (a balance or a total), or [hiddenAmountText] when balances are
  /// hidden.
  String balance(String text) => hideBalances ? hiddenAmountText : text;

  @override
  bool operator ==(Object other) =>
      other is BookPreferences &&
      other.labels == labels &&
      other.dateFormat == dateFormat &&
      other.showTime == showTime &&
      other.hideBalances == hideBalances &&
      other.newestFirst == newestFirst &&
      other.confirmBeforeDelete == confirmBeforeDelete &&
      other.defaultEntryType == defaultEntryType;

  @override
  int get hashCode => Object.hash(
    labels,
    dateFormat,
    showTime,
    hideBalances,
    newestFirst,
    confirmBeforeDelete,
    defaultEntryType,
  );
}

/// What a hidden balance is shown as.
const String hiddenAmountText = '••••';
