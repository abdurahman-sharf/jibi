import '../../../core/models/models.dart';
import 'report_models.dart';

/// Writes a [ReportDocument] as plain text for a chat message (WhatsApp) or
/// any share target.
///
/// It is a summary: the figures and at most [maxRows] table rows. A long
/// statement keeps its most recent rows (each row states its running balance,
/// so the tail stays consistent) and points to the PDF for the rest. Bold
/// headings use the `*...*` marks WhatsApp understands; other apps show them
/// as plain asterisks, which is harmless.
final class ReportTextBuilder {
  const ReportTextBuilder({this.maxRows = 30, this.appName = 'جيبي'});

  /// Right-to-left mark. Every line starts with one so a line that begins with
  /// a Latin word or a transaction number is still laid out right to left.
  static const _rlm = '\u200F';

  final int maxRows;
  final String appName;

  /// Reports whose rows run oldest to newest: when too long, the newest are
  /// kept.
  static const _chronological = <ReportKind>{
    ReportKind.accountStatement,
    ReportKind.accountMonthlyStatement,
    ReportKind.categoryMonthly,
    ReportKind.walletStatement,
  };

  String build(ReportDocument document) {
    final lines = <String>[];
    void add(String line) => lines.add('$_rlm$line');

    add('*${document.title}*');
    final branding = document.branding;
    if (branding != null) {
      final name = branding.displayName;
      if (name != null) add('الصادر من: $name');
      if (branding.phone != null) add('الهاتف: ${branding.phone}');
    }
    for (final info in document.info) {
      add('${info.label}: ${info.value}');
    }

    var budget = maxRows;
    var hidden = 0;
    for (final block in document.blocks) {
      lines.add('');
      final heading = block.heading;
      if (heading != null && heading.isNotEmpty) add('*$heading*');
      for (final figure in block.figures) {
        add('${figure.label}: ${figure.value}');
      }
      final table = block.table;
      if (table != null) {
        if (table.rows.isEmpty) {
          final message = table.emptyMessage;
          if (message != null) add(message);
        } else {
          final shown = _visibleRows(document.kind, table.rows, budget);
          budget -= shown.length;
          hidden += table.rows.length - shown.length;
          for (final row in shown) {
            add('• ${_rowText(table.columns, row, block.currencyCode)}');
          }
          final totals = table.totals;
          if (totals != null) {
            add('*${_rowText(table.columns, totals, block.currencyCode)}*');
          }
        }
      }
      final note = block.note;
      if (note != null && note.isNotEmpty) add(note);
    }
    if (document.hasNoData) {
      lines.add('');
      for (final note in document.notes) {
        add(note);
      }
    }
    if (hidden > 0) {
      lines.add('');
      add(
        _chronological.contains(document.kind)
            ? 'عُرضت أحدث الصفوف فقط ($hidden صفاً أقدم غير معروض). '
                  'التفاصيل الكاملة في ملف PDF.'
            : 'عُرضت الصفوف الأولى فقط ($hidden صفاً غير معروض). '
                  'التفاصيل الكاملة في ملف PDF.',
      );
    }
    lines.add('');
    add('$appName — ${BookTransaction.formatStamp(document.generatedAt)}');
    return lines.join('\n');
  }

  List<List<ReportCell>> _visibleRows(
    ReportKind kind,
    List<List<ReportCell>> rows,
    int budget,
  ) {
    if (budget <= 0) return const <List<ReportCell>>[];
    if (rows.length <= budget) return rows;
    return _chronological.contains(kind)
        ? rows.sublist(rows.length - budget)
        : rows.sublist(0, budget);
  }

  /// "2024-12-13 | يوم موت (TX-000001) | مدين 30,000 | الرصيد 31,000 مدين":
  /// text cells as they are, amounts under their column title, empty cells
  /// left out.
  String _rowText(
    List<ReportColumn> columns,
    List<ReportCell> row,
    String? currencyCode,
  ) {
    final parts = <String>[];
    for (var index = 0; index < row.length && index < columns.length; index++) {
      final text = row[index].text.trim();
      if (text.isEmpty || text == '–') continue;
      final column = columns[index];
      switch (column.kind) {
        case ReportColumnKind.text:
          // The currency is already in the block heading.
          if (currencyCode != null && text == currencyCode) continue;
          parts.add(text);
        case ReportColumnKind.amount:
          parts.add('${column.title} $text');
        case ReportColumnKind.balance:
          parts.add('${column.title} $text');
      }
    }
    return parts.join(' | ');
  }
}
