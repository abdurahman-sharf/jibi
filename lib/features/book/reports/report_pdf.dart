import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/models/models.dart';
import '../domain/book_labels.dart';
import 'report_models.dart';

/// The Arabic font files embedded in report PDFs (Tajawal, SIL OFL 1.1).
final class ReportFonts {
  const ReportFonts({required this.regular, required this.bold});

  final Uint8List regular;
  final Uint8List bold;
}

/// Keeps dates and other hyphenated numbers readable inside Arabic text.
///
/// The bidi step of the pdf package resolves the hyphen of "2026-09-20" as a
/// neutral inside right-to-left text and reverses the groups (it would print
/// "20-09-2026"). A slash is resolved correctly, so in text that contains
/// Arabic letters a hyphen between two digits is written as a slash
/// ("2026/09/20"). Text without Arabic (a lone date, an amount, "TX-000001")
/// is already laid out correctly and is left alone.
///
/// No bidi control characters are used on purpose: the pdf package replaces
/// every character the font lacks with a placeholder box and splits the text
/// there, and the font has no glyph for them. For the same reason cell texts
/// start with Arabic (the first strong character decides the paragraph
/// direction), for example "يوم موت (TX-000001)" rather than "TX-000001 - ...".
String pdfBidiSafe(String text) =>
    RegExp(r'[\u0600-\u06FF]').hasMatch(text)
    ? text.replaceAllMapped(RegExp(r'(?<=\d)-(?=\d)'), (_) => '/')
    : text;

/// Draws a [ReportDocument] as an A4 PDF: Arabic (shaped and right-to-left),
/// a pinned table header on every page, page numbers, totals in bold, and the
/// debit/credit side written out as well as tinted.
///
/// The `pdf` package lays tables out left to right, so the columns are
/// reversed to put the first column at the right edge.
final class ReportPdfRenderer {
  const ReportPdfRenderer({
    required this.fonts,
    this.labels = BookLabels.standard,
    this.appName = 'جيبي',
  });

  final ReportFonts fonts;
  final BookLabels labels;
  final String appName;

  static const PdfColor _ink = PdfColor.fromInt(0xFF12251F);
  static const PdfColor _muted = PdfColor.fromInt(0xFF5B6E67);
  static const PdfColor _green = PdfColor.fromInt(0xFF0F5747);
  static const PdfColor _debit = PdfColor.fromInt(0xFFB3261E);
  static const PdfColor _mint = PdfColor.fromInt(0xFFE3EEE8);
  static const PdfColor _zebra = PdfColor.fromInt(0xFFF6F9F7);
  static const PdfColor _line = PdfColor.fromInt(0xFFC9D6D0);
  static const PdfColor _total = PdfColor.fromInt(0xFFEDEDED);

  Future<Uint8List> render(ReportDocument document) async {
    final regular = pw.Font.ttf(ByteData.sublistView(fonts.regular));
    final bold = pw.Font.ttf(ByteData.sublistView(fonts.bold));
    final pdf = pw.Document(
      title: document.title,
      author: appName,
      creator: appName,
      subject: document.info.map((item) => item.value).join(' · '),
    );
    pw.TextStyle style({
      double size = 9,
      bool isBold = false,
      PdfColor color = _ink,
    }) => pw.TextStyle(
      font: isBold ? bold : regular,
      fontBold: bold,
      fontSize: size,
      color: color,
    );

    pw.Widget text(
      String value, {
      double size = 9,
      bool isBold = false,
      PdfColor color = _ink,
      pw.TextAlign align = pw.TextAlign.right,
    }) => pw.Text(
      pdfBidiSafe(value),
      textDirection: pw.TextDirection.rtl,
      textAlign: align,
      style: style(size: size, isBold: isBold, color: color),
    );

    PdfColor sideColor(BalanceSide? side) => switch (side) {
      BalanceSide.debit => _debit,
      BalanceSide.credit => _green,
      _ => _ink,
    };

    // A picture that cannot be read is left out: a report is never refused
    // because of a damaged logo.
    pw.ImageProvider? picture(Uint8List? bytes) {
      if (bytes == null) return null;
      try {
        return pw.MemoryImage(bytes);
      } on Object {
        return null;
      }
    }

    pw.Widget letterhead(ReportBranding branding) {
      final logo = picture(branding.logo);
      pw.Widget block(
        List<String?> lines, {
        required pw.CrossAxisAlignment align,
        required pw.TextDirection direction,
        required pw.TextAlign textAlign,
      }) {
        final shown = [
          for (final line in lines)
            if (line != null && line.isNotEmpty) line,
        ];
        return pw.Column(
          crossAxisAlignment: align,
          mainAxisSize: pw.MainAxisSize.min,
          children: [
            for (var index = 0; index < shown.length; index++)
              pw.Padding(
                padding: const pw.EdgeInsets.only(bottom: 2),
                child: pw.Text(
                  pdfBidiSafe(shown[index]),
                  textDirection: direction,
                  textAlign: textAlign,
                  style: style(
                    size: index == 0 ? 12.5 : 8.5,
                    isBold: index == 0,
                    color: index == 0 ? _green : _muted,
                  ),
                ),
              ),
          ],
        );
      }

      final contact = [
        // No Arabic label next to the digits: the bidi step would reorder them.
        if (branding.phone != null) branding.phone!,
        if (branding.email != null) branding.email!,
      ].join('  ·  ');
      final arabic = [
        branding.nameAr,
        branding.addressAr,
        if (branding.nameAr != null || branding.nameEn == null) contact,
      ];
      final english = [
        branding.nameEn,
        branding.addressEn,
        if (branding.nameAr == null && branding.nameEn != null) contact,
      ];
      final hasArabic = arabic.any((line) => line != null && line.isNotEmpty);
      final hasEnglish = english.any((line) => line != null && line.isNotEmpty);
      return pw.Container(
        margin: const pw.EdgeInsets.only(bottom: 10),
        padding: const pw.EdgeInsets.only(bottom: 8),
        decoration: const pw.BoxDecoration(
          border: pw.Border(bottom: pw.BorderSide(color: _green, width: 1)),
        ),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            if (logo != null)
              pw.Container(
                width: 58,
                height: 58,
                margin: const pw.EdgeInsets.only(left: 10),
                child: pw.Image(logo, fit: pw.BoxFit.contain),
              ),
            if (hasArabic)
              pw.Expanded(
                // In this right-to-left page a column's "start" is its right edge.
                child: block(
                  arabic,
                  align: pw.CrossAxisAlignment.start,
                  direction: pw.TextDirection.rtl,
                  textAlign: pw.TextAlign.right,
                ),
              )
            else
              pw.Spacer(),
            if (hasEnglish)
              pw.Expanded(
                child: block(
                  english,
                  align: pw.CrossAxisAlignment.end,
                  direction: pw.TextDirection.ltr,
                  textAlign: pw.TextAlign.left,
                ),
              ),
          ],
        ),
      );
    }

    pw.Widget signatures(ReportBranding branding) {
      final signature = picture(branding.signature);
      final stamp = picture(branding.stamp);
      pw.Widget slot(String label, pw.ImageProvider image, double height) =>
          pw.Column(
            mainAxisSize: pw.MainAxisSize.min,
            children: [
              pw.SizedBox(
                height: height,
                child: pw.Image(image, fit: pw.BoxFit.contain),
              ),
              pw.SizedBox(height: 3),
              text(label, size: 8, color: _muted, align: pw.TextAlign.center),
            ],
          );
      return pw.Padding(
        padding: const pw.EdgeInsets.only(top: 22),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            if (signature != null) slot('التوقيع', signature, 52) else pw.SizedBox(),
            if (stamp != null) slot('الختم', stamp, 78) else pw.SizedBox(),
          ],
        ),
      );
    }

    pw.Widget infoTable() => pw.Table(
      columnWidths: const {
        0: pw.FlexColumnWidth(3),
        1: pw.FlexColumnWidth(1.4),
      },
      border: const pw.TableBorder(
        horizontalInside: pw.BorderSide(color: _line, width: 0.4),
        bottom: pw.BorderSide(color: _line, width: 0.4),
        top: pw.BorderSide(color: _line, width: 0.4),
      ),
      children: [
        for (final item in [
          ...document.info,
          ReportInfo(
            'تاريخ الإصدار',
            BookTransaction.formatStamp(document.generatedAt),
          ),
        ])
          pw.TableRow(
            children: [
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(vertical: 3, horizontal: 6),
                child: text(item.value),
              ),
              pw.Container(
                color: _mint,
                padding: const pw.EdgeInsets.symmetric(vertical: 3, horizontal: 6),
                child: text(item.label, isBold: true, color: _green),
              ),
            ],
          ),
      ],
    );

    pw.Widget figures(List<ReportFigure> items) => pw.Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final figure in items)
          pw.Container(
            width: 122,
            padding: const pw.EdgeInsets.all(7),
            decoration: pw.BoxDecoration(
              color: _zebra,
              border: pw.Border.all(color: _line, width: 0.5),
              borderRadius: const pw.BorderRadius.all(pw.Radius.circular(5)),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                text(figure.label, size: 8, color: _muted),
                pw.SizedBox(height: 3),
                text(
                  figure.value,
                  size: 11,
                  isBold: true,
                  color: sideColor(figure.side),
                ),
              ],
            ),
          ),
      ],
    );

    pw.Widget table(ReportTable data) {
      // Columns are reversed: the first column is drawn at the right edge.
      final columns = data.columns.reversed.toList();
      List<ReportCell> visual(List<ReportCell> cells) => [
        for (var index = columns.length - 1; index >= 0; index--)
          index < cells.length ? cells[index] : ReportCell.empty,
      ];
      pw.Widget cell(ReportCell cell, {bool total = false}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 5),
        child: text(
          cell.text,
          isBold: cell.bold || total,
          color: sideColor(cell.side),
        ),
      );
      final rows = <pw.TableRow>[
        pw.TableRow(
          repeat: true,
          decoration: const pw.BoxDecoration(color: _mint),
          children: [
            for (final column in columns)
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(vertical: 5, horizontal: 5),
                child: text(
                  column.title,
                  isBold: true,
                  color: _green,
                  size: 9.5,
                ),
              ),
          ],
        ),
      ];
      for (var index = 0; index < data.rows.length; index++) {
        rows.add(
          pw.TableRow(
            decoration: pw.BoxDecoration(
              color: index.isOdd ? _zebra : PdfColors.white,
            ),
            children: [for (final c in visual(data.rows[index])) cell(c)],
          ),
        );
      }
      if (data.totals != null) {
        rows.add(
          pw.TableRow(
            decoration: const pw.BoxDecoration(color: _total),
            children: [
              for (final c in visual(data.totals!)) cell(c, total: true),
            ],
          ),
        );
      }
      return pw.Table(
        columnWidths: {
          for (var index = 0; index < columns.length; index++)
            index: pw.FlexColumnWidth(columns[index].weight),
        },
        border: const pw.TableBorder(
          top: pw.BorderSide(color: _line, width: 0.5),
          bottom: pw.BorderSide(color: _line, width: 0.5),
          left: pw.BorderSide(color: _line, width: 0.5),
          right: pw.BorderSide(color: _line, width: 0.5),
          horizontalInside: pw.BorderSide(color: _line, width: 0.3),
          verticalInside: pw.BorderSide(color: _line, width: 0.3),
        ),
        defaultVerticalAlignment: pw.TableCellVerticalAlignment.middle,
        children: rows,
      );
    }

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        // The default limit (20 pages) would refuse a long statement.
        maxPages: 5000,
        textDirection: pw.TextDirection.rtl,
        theme: pw.ThemeData.withFont(base: regular, bold: bold),
        margin: const pw.EdgeInsets.fromLTRB(30, 30, 30, 34),
        header: (context) => context.pageNumber == 1
            ? pw.SizedBox()
            : pw.Padding(
                padding: const pw.EdgeInsets.only(bottom: 8),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    text(document.title, size: 9, isBold: true, color: _green),
                    text(
                      document.info.isEmpty ? '' : document.info.first.value,
                      size: 9,
                      color: _muted,
                    ),
                  ],
                ),
              ),
        footer: (context) => pw.Container(
          padding: const pw.EdgeInsets.only(top: 6),
          decoration: const pw.BoxDecoration(
            border: pw.Border(top: pw.BorderSide(color: _line, width: 0.4)),
          ),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              text('$appName — مدونة الحسابات', size: 8, color: _muted),
              text(
                'صفحة ${context.pageNumber} من ${context.pagesCount}',
                size: 8,
                color: _muted,
              ),
              text(
                BookTransaction.formatStamp(document.generatedAt),
                size: 8,
                color: _muted,
              ),
            ],
          ),
        ),
        build: (context) => [
          if (document.branding?.hasLetterhead ?? false)
            letterhead(document.branding!),
          pw.Container(
            padding: const pw.EdgeInsets.only(bottom: 6),
            alignment: pw.Alignment.centerRight,
            child: text(document.title, size: 19, isBold: true, color: _green),
          ),
          pw.SizedBox(height: 4),
          infoTable(),
          for (final block in document.blocks) ...[
            pw.SizedBox(height: 14),
            if (block.heading != null)
              pw.Container(
                width: double.infinity,
                padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 7),
                color: _green,
                child: text(
                  block.heading!,
                  size: 11,
                  isBold: true,
                  color: PdfColors.white,
                ),
              ),
            if (block.heading != null) pw.SizedBox(height: 7),
            if (block.figures.isNotEmpty) ...[
              figures(block.figures),
              pw.SizedBox(height: 10),
            ],
            if (block.table != null) table(block.table!),
            if (block.table != null &&
                block.table!.rows.isEmpty &&
                block.table!.emptyMessage != null)
              pw.Padding(
                padding: const pw.EdgeInsets.only(top: 6),
                child: text(
                  block.table!.emptyMessage!,
                  color: _muted,
                ),
              ),
            if (block.table != null &&
                block.table!.rows.length <= 1 &&
                block.table!.emptyMessage != null &&
                block.table!.rows.isNotEmpty)
              pw.Padding(
                padding: const pw.EdgeInsets.only(top: 6),
                child: text(
                  block.table!.emptyMessage!,
                  color: _muted,
                ),
              ),
          ],
          if (document.notes.isNotEmpty) ...[
            pw.SizedBox(height: 12),
            for (final note in document.notes)
              pw.Padding(
                padding: const pw.EdgeInsets.only(bottom: 3),
                child: text(note, size: 8, color: _muted),
              ),
          ],
          if (document.branding?.hasSignatures ?? false)
            signatures(document.branding!),
        ],
      ),
    );
    return pdf.save();
  }
}
