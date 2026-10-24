import 'dart:typed_data';

import '../../../core/models/models.dart';

/// The reports of the accounts book.
enum ReportKind {
  /// Total debit / credit / net of a category, per currency.
  categoryTotals,

  /// Every account of a category with its debit, credit and balance.
  categoryDetails,

  /// A category's movement month by month.
  categoryMonthly,

  /// An account's transactions between two dates.
  accountStatement,

  /// An account's transactions for one month.
  accountMonthlyStatement,

  /// A wallet's movements between two dates.
  walletStatement,
}

/// How a column's cells are written in a spreadsheet.
enum ReportColumnKind {
  text,

  /// A plain amount (debit or credit): a number cell.
  amount,

  /// A balance: a number plus its side (debit/credit/settled).
  balance,
}

final class ReportColumn {
  const ReportColumn(this.title, {this.kind = ReportColumnKind.text, this.weight = 1});

  final String title;
  final ReportColumnKind kind;

  /// Relative width.
  final double weight;
}

/// One table cell. [text] is what a person reads; the numeric fields let a
/// spreadsheet keep real numbers.
final class ReportCell {
  const ReportCell(this.text, {this.amountMinor, this.side, this.bold = false});

  static const empty = ReportCell('');

  final String text;

  /// Absolute amount in minor units for amount/balance cells.
  final int? amountMinor;

  /// For a balance: which side it is on. For a debit or credit amount: that
  /// side, so it can be tinted. Colour is only a helper; the side is always
  /// also written in [text] or in the column title.
  final BalanceSide? side;
  final bool bold;
}

final class ReportTable {
  const ReportTable({
    required this.columns,
    required this.rows,
    this.totals,
    this.emptyMessage,
  });

  final List<ReportColumn> columns;
  final List<List<ReportCell>> rows;

  /// A closing row (drawn bold) after the data rows.
  final List<ReportCell>? totals;

  /// Shown instead of the table when there are no rows.
  final String? emptyMessage;
}

/// A labelled figure of a summary strip ("إجمالي المدين": "30,100").
final class ReportFigure {
  const ReportFigure(this.label, this.value, {this.side});

  final String label;
  final String value;
  final BalanceSide? side;
}

/// One currency's part of a report (or the whole report when it has only
/// one). Currencies are never added together, so each gets its own block.
final class ReportBlock {
  const ReportBlock({
    this.heading,
    this.currencyCode,
    this.fractionDigits = 0,
    this.figures = const <ReportFigure>[],
    this.table,
    this.note,
  });

  final String? heading;
  final String? currencyCode;

  /// Decimals of [currencyCode], for spreadsheet number formats.
  final int fractionDigits;
  final List<ReportFigure> figures;
  final ReportTable? table;
  final String? note;
}

final class ReportInfo {
  const ReportInfo(this.label, this.value);

  final String label;
  final String value;
}

/// Who issues a report, taken from the user's profile: what is printed in the
/// letterhead (logo, names, contact) and at the end (signature, stamp). A
/// picture the user switched off is already absent here.
///
/// Only plain data, so it can be sent to a background isolate.
final class ReportBranding {
  const ReportBranding({
    this.nameAr,
    this.nameEn,
    this.addressAr,
    this.addressEn,
    this.phone,
    this.email,
    this.logo,
    this.signature,
    this.stamp,
  });

  /// Null when the profile has nothing to print.
  static ReportBranding? fromProfile(UserProfile profile) {
    final branding = ReportBranding(
      nameAr: profile.nameAr,
      nameEn: profile.nameEn,
      addressAr: profile.addressAr,
      addressEn: profile.addressEn,
      phone: profile.phone,
      email: profile.email,
      logo: profile.showLogo ? profile.logo : null,
      signature: profile.showSignature ? profile.signature : null,
      stamp: profile.showStamp ? profile.stamp : null,
    );
    return branding.isEmpty ? null : branding;
  }

  final String? nameAr;
  final String? nameEn;
  final String? addressAr;
  final String? addressEn;
  final String? phone;
  final String? email;
  final Uint8List? logo;
  final Uint8List? signature;
  final Uint8List? stamp;

  bool get isEmpty =>
      nameAr == null &&
      nameEn == null &&
      addressAr == null &&
      addressEn == null &&
      phone == null &&
      email == null &&
      logo == null &&
      signature == null &&
      stamp == null;

  /// The issuer's name for a short place (a text header): Arabic first.
  String? get displayName => nameAr ?? nameEn;

  /// Whether the letterhead has anything to draw.
  bool get hasLetterhead =>
      logo != null ||
      nameAr != null ||
      nameEn != null ||
      addressAr != null ||
      addressEn != null ||
      phone != null ||
      email != null;

  bool get hasSignatures => signature != null || stamp != null;
}

/// Everything a report says, independent of how it is drawn. The on-screen
/// preview, the PDF, the spreadsheet and the shared text are all produced from
/// one of these, so their numbers can never disagree.
///
/// Only plain data, so it can be sent to a background isolate.
final class ReportDocument {
  const ReportDocument({
    required this.kind,
    required this.title,
    required this.info,
    required this.blocks,
    required this.generatedAt,
    required this.fileBaseName,
    this.notes = const <String>[],
    this.branding,
  });

  final ReportKind kind;
  final String title;
  final List<ReportInfo> info;
  final List<ReportBlock> blocks;
  final DateTime generatedAt;

  /// A file name without extension.
  final String fileBaseName;
  final List<String> notes;

  /// The issuer (letterhead and signatures); null when none is set up.
  final ReportBranding? branding;

  /// Whether there is nothing to show besides the header.
  bool get hasNoData => blocks.isEmpty;

  /// Rows of every table (used to decide how big an export is).
  int get rowCount => blocks.fold<int>(
    0,
    (sum, block) => sum + (block.table?.rows.length ?? 0),
  );
}
