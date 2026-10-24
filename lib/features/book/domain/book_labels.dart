import '../../../core/models/models.dart';

/// User-facing wording of the two sides. Internally the app only knows DEBIT
/// and CREDIT; this is presentation, so it can be customised without touching
/// any rule. Screens and reports share this one class so a report can never
/// word a balance differently from the screen it came from.
final class BookLabels {
  const BookLabels({
    this.debit = 'مدين',
    this.credit = 'دائن',
    this.debitHint = 'لنا',
    this.creditHint = 'علينا',
    this.settled = 'متعادل',
  });

  static const standard = BookLabels();

  /// The wording chosen in the settings. A custom word already says who owes
  /// whom ("مستحق لي"), so the standard "(لنا)"/"(علينا)" hints are dropped as
  /// soon as either side is renamed.
  factory BookLabels.fromSettings(AppSettings settings) {
    final debit = settings.debitLabel;
    final credit = settings.creditLabel;
    if (debit == null && credit == null) {
      return standard;
    }
    return BookLabels(
      debit: debit ?? standard.debit,
      credit: credit ?? standard.credit,
      debitHint: '',
      creditHint: '',
    );
  }

  final String debit;
  final String credit;

  /// "(لنا)": what people owe the user. Empty for custom wording.
  final String debitHint;

  /// "(علينا)": what the user owes. Empty for custom wording.
  final String creditHint;
  final String settled;

  String side(BalanceSide side) => switch (side) {
    BalanceSide.debit => debit,
    BalanceSide.credit => credit,
    BalanceSide.settled => settled,
  };

  String entry(EntryType type) => type == EntryType.debit ? debit : credit;

  /// "مدين (لنا)", or just the word when there is no hint.
  String get debitWithHint => debitHint.isEmpty ? debit : '$debit ($debitHint)';

  /// "دائن (علينا)", or just the word when there is no hint.
  String get creditWithHint =>
      creditHint.isEmpty ? credit : '$credit ($creditHint)';

  String entryWithHint(EntryType type) =>
      type == EntryType.debit ? debitWithHint : creditWithHint;

  /// The hint of a balance side as "– لنا", or empty.
  String sideHint(BalanceSide side) => switch (side) {
    BalanceSide.debit => debitHint,
    BalanceSide.credit => creditHint,
    BalanceSide.settled => '',
  };

  @override
  bool operator ==(Object other) =>
      other is BookLabels &&
      other.debit == debit &&
      other.credit == credit &&
      other.debitHint == debitHint &&
      other.creditHint == creditHint &&
      other.settled == settled;

  @override
  int get hashCode =>
      Object.hash(debit, credit, debitHint, creditHint, settled);
}
