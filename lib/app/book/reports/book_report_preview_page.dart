import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/models/models.dart';
import '../../../features/book/book.dart';
import '../../../features/book/reports/report_exporter.dart';
import '../../../features/book/reports/report_models.dart';
import '../../../shared/widgets/external_activity_scope.dart';
import '../../../shared/widgets/jibi_design.dart';
import '../../../shared/widgets/jibi_feedback.dart';
import '../book_export_scope.dart';
import '../book_widgets.dart';

/// Opens the preview of the report [build] produces.
Future<void> openReportPreview(
  BuildContext context,
  BookServices book,
  Future<ReportDocument> Function() build,
) => Navigator.of(context, rootNavigator: true).push<void>(
  MaterialPageRoute<void>(
    builder: (_) => BookReportPreviewPage(book: book, build: build),
  ),
);

/// A report on screen, drawn from the same [ReportDocument] the PDF, the
/// spreadsheet and the shared text are made from, with the export actions.
class BookReportPreviewPage extends StatefulWidget {
  const BookReportPreviewPage({
    required this.book,
    required this.build,
    super.key,
  });

  final BookServices book;
  final Future<ReportDocument> Function() build;

  @override
  State<BookReportPreviewPage> createState() => _BookReportPreviewPageState();
}

class _BookReportPreviewPageState extends State<BookReportPreviewPage> {
  late Future<ReportDocument> _document = widget.build();
  bool _busy = false;

  void _retry() {
    setState(() {
      _document = widget.build();
    });
  }

  Future<void> _export(
    Future<void> Function(ReportExporter exporter) action,
  ) async {
    final exporter = widget.book.exporter;
    final authorize = BookExportScope.maybeOf(context);
    if (exporter == null || authorize == null || _busy) return;
    if (!await authorize(context, title: 'تصدير التقرير')) return;
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      await ExternalActivityScope.of(context)(
        () => action(exporter),
        holdUntilResumed: true,
      );
    } on Object catch (error) {
      if (mounted) showBookError(context, error, 'تعذر تصدير التقرير.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseWhatsApp(ReportDocument document) async {
    final choice = await showModalBottomSheet<_WhatsAppChoice>(
      context: context,
      showDragHandle: true,
      useRootNavigator: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('whatsapp-pdf'),
              leading: const Icon(Icons.picture_as_pdf_outlined),
              title: const Text('إرسال ملف PDF'),
              subtitle: const Text('التقرير كاملاً بتنسيقه'),
              onTap: () => Navigator.of(context).pop(_WhatsAppChoice.pdf),
            ),
            ListTile(
              key: const Key('whatsapp-text'),
              leading: const Icon(Icons.notes_outlined),
              title: const Text('إرسال ملخص نصي'),
              subtitle: const Text('الأرقام الأساسية وآخر الصفوف في رسالة'),
              onTap: () => Navigator.of(context).pop(_WhatsAppChoice.text),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    await _export(
      (exporter) => switch (choice) {
        _WhatsAppChoice.pdf => exporter.shareFile(
          document,
          ReportFormat.pdf,
          target: ReportShareTarget.whatsApp,
        ),
        _WhatsAppChoice.text => exporter.shareText(
          document,
          target: ReportShareTarget.whatsApp,
        ),
      },
    );
  }

  Future<void> _chooseMore(ReportDocument document) async {
    final choice = await showModalBottomSheet<_MoreChoice>(
      context: context,
      showDragHandle: true,
      useRootNavigator: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('report-more-save-pdf'),
              leading: const Icon(Icons.save_alt_outlined),
              title: const Text('حفظ PDF على الجهاز'),
              subtitle: const Text('اختر المجلد الذي تريده'),
              onTap: () => Navigator.of(context).pop(_MoreChoice.savePdf),
            ),
            ListTile(
              key: const Key('report-more-save-xlsx'),
              leading: const Icon(Icons.save_alt_outlined),
              title: const Text('حفظ Excel على الجهاز'),
              onTap: () => Navigator.of(context).pop(_MoreChoice.saveXlsx),
            ),
            ListTile(
              key: const Key('report-more-print'),
              leading: const Icon(Icons.print_outlined),
              title: const Text('طباعة'),
              subtitle: const Text('يفتح شاشة الطباعة في هاتفك'),
              onTap: () => Navigator.of(context).pop(_MoreChoice.print),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    Future<void> save(ReportFormat format) async {
      await _export((exporter) async {
        final kept = await exporter.saveFile(document, format);
        if (kept && mounted) showJibiMessage(context, 'تم حفظ الملف.');
      });
    }

    switch (choice) {
      case _MoreChoice.savePdf:
        await save(ReportFormat.pdf);
      case _MoreChoice.saveXlsx:
        await save(ReportFormat.xlsx);
      case _MoreChoice.print:
        await _export((exporter) => exporter.printDocument(document));
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<ReportDocument>(
    future: _document,
    builder: (context, snapshot) {
      final document = snapshot.data;
      return Scaffold(
        appBar: AppBar(title: Text(document?.title ?? 'التقرير')),
        body: snapshot.hasError
            ? JibiErrorState(
                message: bookErrorMessage(
                  snapshot.error!,
                  'تعذر إنشاء التقرير. حاول مرة أخرى.',
                ),
                onRetry: _retry,
              )
            : document == null
            ? const JibiLoadingState(message: 'جارٍ إعداد التقرير…')
            : ReportDocumentView(document: document, book: widget.book),
        bottomNavigationBar:
            document == null ||
                widget.book.exporter == null ||
                BookExportScope.maybeOf(context) == null
            ? null
            : _ExportBar(
                enabled: !_busy && !document.hasNoData,
                busy: _busy,
                onPdf: () => _export(
                  (exporter) => exporter.shareFile(document, ReportFormat.pdf),
                ),
                onExcel: () => _export(
                  (exporter) => exporter.shareFile(document, ReportFormat.xlsx),
                ),
                onWhatsApp: () => _chooseWhatsApp(document),
                onShare: () =>
                    _export((exporter) => exporter.shareText(document)),
                onMore: () => _chooseMore(document),
              ),
      );
    },
  );
}

enum _WhatsAppChoice { pdf, text }

enum _MoreChoice { savePdf, saveXlsx, print }

class _ExportBar extends StatelessWidget {
  const _ExportBar({
    required this.enabled,
    required this.busy,
    required this.onPdf,
    required this.onExcel,
    required this.onWhatsApp,
    required this.onShare,
    required this.onMore,
  });

  final bool enabled;
  final bool busy;
  final VoidCallback onPdf;
  final VoidCallback onExcel;
  final VoidCallback onWhatsApp;
  final VoidCallback onShare;

  /// Save to the device, print.
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) => Material(
    elevation: 8,
    color: Theme.of(context).colorScheme.surface,
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: busy
            ? const SizedBox(
                height: 56,
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 12),
                      Text('جارٍ تجهيز الملف…'),
                    ],
                  ),
                ),
              )
            : Row(
                children: [
                  _ExportButton(
                    buttonKey: const Key('report-export-pdf'),
                    icon: Icons.picture_as_pdf_outlined,
                    label: 'PDF',
                    onPressed: enabled ? onPdf : null,
                  ),
                  _ExportButton(
                    buttonKey: const Key('report-export-xlsx'),
                    icon: Icons.table_chart_outlined,
                    label: 'Excel',
                    onPressed: enabled ? onExcel : null,
                  ),
                  _ExportButton(
                    buttonKey: const Key('report-export-whatsapp'),
                    icon: Icons.chat_outlined,
                    label: 'واتساب',
                    onPressed: enabled ? onWhatsApp : null,
                  ),
                  _ExportButton(
                    buttonKey: const Key('report-export-text'),
                    icon: Icons.share_outlined,
                    label: 'مشاركة',
                    onPressed: enabled ? onShare : null,
                  ),
                  _ExportButton(
                    buttonKey: const Key('report-export-more'),
                    icon: Icons.more_horiz,
                    label: 'حفظ وطباعة',
                    onPressed: enabled ? onMore : null,
                  ),
                ],
              ),
      ),
    ),
  );
}

class _ExportButton extends StatelessWidget {
  const _ExportButton({
    required this.buttonKey,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final Key buttonKey;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final color = onPressed == null
        ? Theme.of(context).disabledColor
        : Theme.of(context).colorScheme.primary;
    return Expanded(
      child: InkWell(
        key: buttonKey,
        borderRadius: BorderRadius.circular(12),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color),
              const SizedBox(height: 2),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The body of a report: header, then per currency its figures and table.
/// Rows are built lazily, so a statement of thousands of rows stays smooth.
class ReportDocumentView extends StatelessWidget {
  const ReportDocumentView({
    required this.document,
    required this.book,
    super.key,
  });

  final ReportDocument document;
  final BookServices book;

  @override
  Widget build(BuildContext context) => CustomScrollView(
    key: const Key('report-view'),
    slivers: [
      if (document.branding?.hasLetterhead ?? false)
        SliverToBoxAdapter(child: _Letterhead(branding: document.branding!)),
      SliverToBoxAdapter(child: _InfoCard(document: document)),
      if (document.hasNoData)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              document.notes.isEmpty
                  ? 'لا توجد بيانات لهذا التقرير.'
                  : document.notes.join('\n'),
              textAlign: TextAlign.center,
              style: TextStyle(color: context.jibiMuted),
            ),
          ),
        ),
      for (final block in document.blocks) ..._blockSlivers(context, block),
      if (!document.hasNoData && document.notes.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              document.notes.join('\n'),
              style: TextStyle(fontSize: 12, color: context.jibiMuted),
            ),
          ),
        ),
      if (document.branding?.hasSignatures ?? false)
        SliverToBoxAdapter(
          child: _Signatures(branding: document.branding!),
        ),
      const SliverToBoxAdapter(child: SizedBox(height: 24)),
    ],
  );

  List<Widget> _blockSlivers(BuildContext context, ReportBlock block) {
    final table = block.table;
    return [
      SliverMainAxisGroup(
        slivers: [
          if (block.heading != null)
            SliverToBoxAdapter(child: _BlockHeading(text: block.heading!)),
          if (block.figures.isNotEmpty)
            SliverToBoxAdapter(child: _Figures(figures: block.figures)),
          if (table != null && table.rows.isEmpty && table.totals == null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  table.emptyMessage ?? 'لا توجد بيانات.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.jibiMuted),
                ),
              ),
            )
          else if (table != null) ...[
            SliverPersistentHeader(
              pinned: true,
              delegate: _TableHeaderDelegate(columns: table.columns),
            ),
            SliverList.builder(
              itemCount: table.rows.length,
              itemBuilder: (context, index) => _TableRow(
                columns: table.columns,
                cells: table.rows[index],
                shaded: index.isOdd,
              ),
            ),
            if (table.totals != null)
              SliverToBoxAdapter(
                child: _TableRow(
                  columns: table.columns,
                  cells: table.totals!,
                  total: true,
                ),
              ),
          ],
          if (block.note != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  block.note!,
                  style: TextStyle(fontSize: 12, color: context.jibiMuted),
                ),
              ),
            ),
        ],
      ),
    ];
  }
}

/// The issuer of the report: logo, names and contact details.
class _Letterhead extends StatelessWidget {
  const _Letterhead({required this.branding});

  final ReportBranding branding;

  @override
  Widget build(BuildContext context) {
    final lines = <String>[
      ?branding.nameAr,
      ?branding.nameEn,
      ?branding.addressAr,
      ?branding.addressEn,
      if (branding.phone != null || branding.email != null)
        [?branding.phone, ?branding.email].join('  ·  '),
    ];
    return Padding(
      key: const Key('report-letterhead'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: BookCard(
        child: Row(
          children: [
            if (branding.logo != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  branding.logo!,
                  width: 52,
                  height: 52,
                  fit: BoxFit.contain,
                  // A damaged picture is left out instead of breaking the page.
                  errorBuilder: (_, _, _) => const SizedBox(width: 52, height: 52),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var index = 0; index < lines.length; index++)
                    Text(
                      lines[index],
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: index == 0
                          ? const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            )
                          : TextStyle(fontSize: 12, color: context.jibiMuted),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The signature and the stamp, printed at the end of the report.
class _Signatures extends StatelessWidget {
  const _Signatures({required this.branding});

  final ReportBranding branding;

  @override
  Widget build(BuildContext context) {
    Widget slot(String label, Uint8List bytes, double height) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.memory(
          bytes,
          height: height,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => SizedBox(height: height),
        ),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(fontSize: 12, color: context.jibiMuted)),
      ],
    );
    return Padding(
      key: const Key('report-signatures'),
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (branding.signature != null)
            slot('التوقيع', branding.signature!, 56)
          else
            const SizedBox.shrink(),
          if (branding.stamp != null)
            slot('الختم', branding.stamp!, 80)
          else
            const SizedBox.shrink(),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.document});

  final ReportDocument document;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
    child: BookCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final info in document.info)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 110,
                    child: Text(
                      info.label,
                      style: TextStyle(color: context.jibiMuted, fontSize: 13),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      info.value,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          Text(
            'تاريخ الإصدار: '
            '${BookTransaction.formatStamp(document.generatedAt)}',
            style: TextStyle(fontSize: 12, color: context.jibiMuted),
          ),
        ],
      ),
    ),
  );
}

class _BlockHeading extends StatelessWidget {
  const _BlockHeading({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: JibiColors.deepGreen,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.w800,
        fontSize: 15,
      ),
    ),
  );
}

class _Figures extends StatelessWidget {
  const _Figures({required this.figures});

  final List<ReportFigure> figures;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final figure in figures)
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 130, maxWidth: 260),
            child: BookCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    figure.label,
                    style: TextStyle(fontSize: 12, color: context.jibiMuted),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    figure.value,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: figure.side == null
                          ? context.jibiInk
                          : context.sideColor(figure.side!),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}

int _flexOf(ReportColumn column) => (column.weight * 10).round().clamp(1, 100);

class _TableHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _TableHeaderDelegate({required this.columns});

  final List<ReportColumn> columns;

  static const double _height = 40;

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => Container(
    height: _height,
    padding: const EdgeInsets.symmetric(horizontal: 16),
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: Row(
      children: [
        for (final column in columns)
          Expanded(
            flex: _flexOf(column),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Text(
                column.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 12.5,
                ),
              ),
            ),
          ),
      ],
    ),
  );

  @override
  bool shouldRebuild(_TableHeaderDelegate oldDelegate) =>
      oldDelegate.columns != columns;
}

class _TableRow extends StatelessWidget {
  const _TableRow({
    required this.columns,
    required this.cells,
    this.shaded = false,
    this.total = false,
  });

  final List<ReportColumn> columns;
  final List<ReportCell> cells;
  final bool shaded;
  final bool total;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      decoration: BoxDecoration(
        color: total
            ? scheme.surfaceContainerHighest
            : shaded
            ? scheme.surfaceContainerLow
            : null,
        border: Border(
          bottom: BorderSide(color: context.jibiMuted.withValues(alpha: 0.15)),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var index = 0; index < columns.length; index++)
            Expanded(
              flex: _flexOf(columns[index]),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: _cell(
                  context,
                  columns[index],
                  index < cells.length ? cells[index] : ReportCell.empty,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _cell(BuildContext context, ReportColumn column, ReportCell cell) {
    if (cell.text.isEmpty) return const SizedBox.shrink();
    final tinted = column.kind != ReportColumnKind.text && cell.side != null;
    final text = Text(
      cell.text,
      maxLines: column.kind == ReportColumnKind.text ? 4 : 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 13,
        fontWeight: total || cell.bold ? FontWeight.w800 : FontWeight.w500,
        color: tinted ? context.sideColor(cell.side!) : context.jibiInk,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    // Amounts keep their digits together on one line when they can.
    return column.kind == ReportColumnKind.text
        ? text
        : Align(
            alignment: AlignmentDirectional.centerStart,
            child: FittedBox(fit: BoxFit.scaleDown, child: text),
          );
  }
}
