import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../../core/models/models.dart';
import '../domain/book_labels.dart';
import 'report_models.dart';

/// Writes a [ReportDocument] as an `.xlsx` workbook (right-to-left sheets).
///
/// One sheet per currency block. Debit, credit and balance amounts are real
/// numbers (with the currency's decimals) so they can be summed; a balance
/// column becomes two columns, the amount and its side. The file is a plain
/// zip of hand-written SpreadsheetML, so no spreadsheet library is needed.
final class ReportXlsxWriter {
  const ReportXlsxWriter({this.labels = BookLabels.standard});

  final BookLabels labels;

  static const String mimeType =
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

  // Style indexes of `styles.xml` (see [_stylesXml]).
  static const int _sTitle = 1;
  static const int _sHeader = 2;
  static const int _sCell = 3;
  static const int _sBoldCell = 4;
  static const int _sAmount0 = 5; // + fraction digits (0..3) -> 5..8
  static const int _sBoldAmount0 = 9; // + fraction digits -> 9..12
  static const int _sLabel = 13;

  Uint8List write(ReportDocument document) {
    final sheets = _sheets(document);
    final archive = Archive();
    void add(String path, String content) =>
        archive.addFile(ArchiveFile.bytes(path, utf8.encode(content)));

    add('[Content_Types].xml', _contentTypes(sheets.length));
    add('_rels/.rels', _rootRels);
    add('xl/workbook.xml', _workbookXml(sheets));
    add('xl/_rels/workbook.xml.rels', _workbookRels(sheets.length));
    add('xl/styles.xml', _stylesXml);
    for (var index = 0; index < sheets.length; index++) {
      add('xl/worksheets/sheet${index + 1}.xml', sheets[index].xml);
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  // ---- sheets ---------------------------------------------------------------

  List<_Sheet> _sheets(ReportDocument document) {
    final names = <String>{};
    String unique(String wanted) {
      var name = _sheetName(wanted);
      var suffix = 2;
      while (!names.add(name.toLowerCase())) {
        final tail = ' ${suffix++}';
        name = '${_sheetName(wanted, reserve: tail.length)}$tail';
      }
      return name;
    }

    if (document.blocks.isEmpty) {
      return [
        _Sheet(unique(document.title), _sheetXml(document, null)),
      ];
    }
    final single = document.blocks.length == 1;
    return [
      for (final block in document.blocks)
        _Sheet(
          unique(
            single
                ? document.title
                : (block.currencyCode ?? block.heading ?? document.title),
          ),
          _sheetXml(document, block),
        ),
    ];
  }

  String _sheetXml(ReportDocument document, ReportBlock? block) {
    final rows = <String>[];
    var rowNumber = 0;
    void addRow(List<String> cells) {
      rowNumber++;
      rows.add('<row r="$rowNumber">${cells.join()}</row>');
    }

    String text(int column, String value, int style) =>
        _textCell(column, rowNumber + 1, value, style);

    addRow([text(0, document.title, _sTitle)]);
    // Who issued the report. Only text: the logo, signature and stamp pictures
    // are drawn in the PDF and the preview, not in the spreadsheet.
    final branding = document.branding;
    if (branding != null) {
      void issuer(String label, String? value) {
        if (value != null) {
          addRow([text(0, label, _sLabel), text(1, value, _sCell)]);
        }
      }

      issuer('الجهة', branding.nameAr);
      issuer('الاسم الإنجليزي', branding.nameEn);
      issuer('العنوان', branding.addressAr);
      issuer('العنوان الإنجليزي', branding.addressEn);
      issuer('الهاتف', branding.phone);
      issuer('البريد الإلكتروني', branding.email);
    }
    for (final item in document.info) {
      addRow([text(0, item.label, _sLabel), text(1, item.value, _sCell)]);
    }
    addRow([
      text(0, 'تاريخ الإصدار', _sLabel),
      text(1, BookTransaction.formatStamp(document.generatedAt), _sCell),
    ]);
    if (block?.heading != null) {
      addRow([text(0, 'العملة', _sLabel), text(1, block!.heading!, _sCell)]);
    }
    for (final figure in block?.figures ?? const <ReportFigure>[]) {
      addRow([text(0, figure.label, _sLabel), text(1, figure.value, _sCell)]);
    }
    for (final note in document.notes) {
      addRow([text(0, note, _sCell)]);
    }

    var widths = <double>[22, 26];
    final table = block?.table;
    if (table != null) {
      addRow(const []);
      final digits = block!.fractionDigits.clamp(0, 3);
      final layout = _layout(table.columns);
      widths = layout.widths;
      addRow([
        for (var column = 0; column < layout.titles.length; column++)
          text(column, layout.titles[column], _sHeader),
      ]);
      if (table.rows.isEmpty && table.emptyMessage != null) {
        addRow([text(0, table.emptyMessage!, _sCell)]);
      }
      for (final row in table.rows) {
        addRow(_dataCells(table.columns, row, digits, rowNumber + 1, bold: false));
      }
      if (table.totals != null) {
        addRow(
          _dataCells(
            table.columns,
            table.totals!,
            digits,
            rowNumber + 1,
            bold: true,
          ),
        );
      }
    }

    final cols = StringBuffer('<cols>');
    for (var index = 0; index < widths.length; index++) {
      cols.write(
        '<col min="${index + 1}" max="${index + 1}" '
        'width="${widths[index].toStringAsFixed(1)}" customWidth="1"/>',
      );
    }
    cols.write('</cols>');
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<sheetViews><sheetView rightToLeft="1" workbookViewId="0"/></sheetViews>'
        '<sheetFormatPr defaultRowHeight="15"/>'
        '$cols<sheetData>${rows.join()}</sheetData>'
        '</worksheet>';
  }

  /// Column titles and widths of the sheet: a balance column is written as an
  /// amount column plus a side column.
  ({List<String> titles, List<double> widths}) _layout(
    List<ReportColumn> columns,
  ) {
    final titles = <String>[];
    final widths = <double>[];
    for (final column in columns) {
      titles.add(column.title);
      widths.add((column.weight * 9).clamp(12, 48).toDouble());
      if (column.kind == ReportColumnKind.balance) {
        titles.add('الجانب');
        widths.add(10);
      }
    }
    return (titles: titles, widths: widths);
  }

  List<String> _dataCells(
    List<ReportColumn> columns,
    List<ReportCell> cells,
    int digits,
    int row, {
    required bool bold,
  }) {
    final result = <String>[];
    var column = 0;
    for (var index = 0; index < columns.length; index++) {
      final cell = index < cells.length ? cells[index] : ReportCell.empty;
      final kind = columns[index].kind;
      final textStyle = (bold || cell.bold) ? _sBoldCell : _sCell;
      switch (kind) {
        case ReportColumnKind.text:
          result.add(_textCell(column++, row, cell.text, textStyle));
        case ReportColumnKind.amount:
          result.add(
            cell.amountMinor == null
                ? _textCell(column++, row, '', textStyle)
                : _numberCell(
                    column++,
                    row,
                    _decimal(cell.amountMinor!, digits),
                    (bold || cell.bold ? _sBoldAmount0 : _sAmount0) + digits,
                  ),
          );
        case ReportColumnKind.balance:
          if (cell.amountMinor == null) {
            result
              ..add(_textCell(column++, row, cell.text, textStyle))
              ..add(_textCell(column++, row, '', textStyle));
          } else {
            result
              ..add(
                _numberCell(
                  column++,
                  row,
                  _decimal(cell.amountMinor!, digits),
                  (bold || cell.bold ? _sBoldAmount0 : _sAmount0) + digits,
                ),
              )
              ..add(
                _textCell(
                  column++,
                  row,
                  labels.side(cell.side ?? BalanceSide.settled),
                  textStyle,
                ),
              );
          }
      }
    }
    return result;
  }

  // ---- cells ----------------------------------------------------------------

  static String _textCell(int column, int row, String value, int style) {
    final ref = '${_columnName(column)}$row';
    if (value.isEmpty) {
      return '<c r="$ref" s="$style"/>';
    }
    return '<c r="$ref" s="$style" t="inlineStr"><is>'
        '<t xml:space="preserve">${_escape(value)}</t></is></c>';
  }

  static String _numberCell(int column, int row, String number, int style) =>
      '<c r="${_columnName(column)}$row" s="$style"><v>$number</v></c>';

  /// `26100` with 2 digits -> `261.00`, exact (no floating point).
  static String _decimal(int minor, int digits) {
    if (digits == 0) return '$minor';
    final negative = minor < 0;
    final magnitude = (negative ? -minor : minor).toString().padLeft(digits + 1, '0');
    final cut = magnitude.length - digits;
    return '${negative ? '-' : ''}${magnitude.substring(0, cut)}.${magnitude.substring(cut)}';
  }

  /// `0 -> A`, `25 -> Z`, `26 -> AA`.
  static String _columnName(int index) {
    var n = index;
    final letters = StringBuffer();
    do {
      letters.write(String.fromCharCode(65 + n % 26));
      n = n ~/ 26 - 1;
    } while (n >= 0);
    return letters.toString().split('').reversed.join();
  }

  /// Escapes XML text and drops characters XML 1.0 cannot carry.
  static String _escape(String value) {
    final buffer = StringBuffer();
    for (final rune in value.runes) {
      final allowed =
          rune == 0x9 ||
          rune == 0xA ||
          rune == 0xD ||
          (rune >= 0x20 && rune <= 0xD7FF) ||
          (rune >= 0xE000 && rune <= 0xFFFD) ||
          (rune >= 0x10000 && rune <= 0x10FFFF);
      if (!allowed) continue;
      switch (rune) {
        case 0x26:
          buffer.write('&amp;');
        case 0x3C:
          buffer.write('&lt;');
        case 0x3E:
          buffer.write('&gt;');
        case 0x22:
          buffer.write('&quot;');
        default:
          buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }

  /// A legal sheet name: at most 31 characters, none of `[]:*?/\`.
  static String _sheetName(String wanted, {int reserve = 0}) {
    final cleaned = wanted
        .replaceAll(RegExp(r'[\[\]:*?/\\]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final limit = 31 - reserve;
    final cut = cleaned.length > limit ? cleaned.substring(0, limit).trim() : cleaned;
    return cut.isEmpty ? 'تقرير' : cut;
  }

  // ---- package parts --------------------------------------------------------

  static String _contentTypes(int sheetCount) =>
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
      '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
      '${[for (var i = 1; i <= sheetCount; i++) '<Override PartName="/xl/worksheets/sheet$i.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'].join()}'
      '</Types>';

  static const String _rootRels =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
      '</Relationships>';

  static String _workbookXml(List<_Sheet> sheets) =>
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
      '<sheets>'
      '${[for (var i = 0; i < sheets.length; i++) '<sheet name="${_escape(sheets[i].name)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>'].join()}'
      '</sheets></workbook>';

  static String _workbookRels(int sheetCount) =>
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '${[for (var i = 1; i <= sheetCount; i++) '<Relationship Id="rId$i" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet$i.xml"/>'].join()}'
      '<Relationship Id="rId${sheetCount + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
      '</Relationships>';

  /// Fonts: 0 normal, 1 bold, 2 bold 14. Fills: 0 none, 1 gray125 (required),
  /// 2 header, 3 totals. Number formats 164..166 are `#,##0` / `.00` / `.000`.
  static const String _stylesXml =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
      '<numFmts count="4">'
      '<numFmt numFmtId="164" formatCode="#,##0"/>'
      '<numFmt numFmtId="165" formatCode="#,##0.00"/>'
      '<numFmt numFmtId="166" formatCode="#,##0.000"/>'
      '<numFmt numFmtId="167" formatCode="#,##0.0"/>'
      '</numFmts>'
      '<fonts count="3">'
      '<font><sz val="11"/><name val="Calibri"/></font>'
      '<font><b/><sz val="11"/><name val="Calibri"/></font>'
      '<font><b/><sz val="14"/><name val="Calibri"/></font>'
      '</fonts>'
      '<fills count="4">'
      '<fill><patternFill patternType="none"/></fill>'
      '<fill><patternFill patternType="gray125"/></fill>'
      '<fill><patternFill patternType="solid"><fgColor rgb="FFE3EEE8"/><bgColor indexed="64"/></patternFill></fill>'
      '<fill><patternFill patternType="solid"><fgColor rgb="FFF2F2F2"/><bgColor indexed="64"/></patternFill></fill>'
      '</fills>'
      '<borders count="2">'
      '<border><left/><right/><top/><bottom/><diagonal/></border>'
      '<border><left style="thin"><color auto="1"/></left><right style="thin"><color auto="1"/></right>'
      '<top style="thin"><color auto="1"/></top><bottom style="thin"><color auto="1"/></bottom><diagonal/></border>'
      '</borders>'
      '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
      '<cellXfs count="14">'
      '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
      '<xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/>'
      '<xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center"/></xf>'
      '<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1"/>'
      '<xf numFmtId="0" fontId="1" fillId="3" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1"/>'
      '<xf numFmtId="164" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1"/>'
      '<xf numFmtId="167" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1"/>'
      '<xf numFmtId="165" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1"/>'
      '<xf numFmtId="166" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1"/>'
      '<xf numFmtId="164" fontId="1" fillId="3" borderId="1" xfId="0" applyNumberFormat="1" applyFont="1" applyFill="1" applyBorder="1"/>'
      '<xf numFmtId="167" fontId="1" fillId="3" borderId="1" xfId="0" applyNumberFormat="1" applyFont="1" applyFill="1" applyBorder="1"/>'
      '<xf numFmtId="165" fontId="1" fillId="3" borderId="1" xfId="0" applyNumberFormat="1" applyFont="1" applyFill="1" applyBorder="1"/>'
      '<xf numFmtId="166" fontId="1" fillId="3" borderId="1" xfId="0" applyNumberFormat="1" applyFont="1" applyFill="1" applyBorder="1"/>'
      '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>'
      '</cellXfs>'
      '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
      '</styleSheet>';
}

final class _Sheet {
  const _Sheet(this.name, this.xml);

  final String name;
  final String xml;
}
