import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../../../core/errors/app_exception.dart';
import '../domain/book_labels.dart';
import 'report_models.dart';
import 'report_pdf.dart';
import 'report_text.dart';
import 'report_xlsx.dart';

enum ReportFormat {
  pdf('pdf', 'application/pdf'),
  xlsx(
    'xlsx',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  );

  const ReportFormat(this.extension, this.mimeType);

  final String extension;
  final String mimeType;
}

/// Where a shared report goes first. WhatsApp is opened directly when it is
/// installed; otherwise (and for [chooser]) the system share sheet is shown.
enum ReportShareTarget { chooser, whatsApp }

/// What the report screens use to send a [ReportDocument] out of the app.
///
/// Nothing is ever kept: a file exists only while the share sheet takes it.
abstract interface class ReportExporter {
  /// Builds the PDF or spreadsheet of [document] and hands it to the share
  /// sheet (or WhatsApp).
  Future<void> shareFile(
    ReportDocument document,
    ReportFormat format, {
    ReportShareTarget target = ReportShareTarget.chooser,
  });

  /// Shares a short text summary of [document].
  Future<void> shareText(
    ReportDocument document, {
    ReportShareTarget target = ReportShareTarget.chooser,
  });

  /// Builds the file and lets the user choose where on the phone to keep it.
  /// Returns false when they cancelled.
  Future<bool> saveFile(ReportDocument document, ReportFormat format);

  /// Opens the system print screen with the PDF of [document].
  Future<void> printDocument(ReportDocument document);
}

typedef ReportFileSave =
    Future<bool> Function(File file, String mimeType, {required String fileName});

typedef ReportFilePrint = Future<void> Function(File file, {String? jobName});

typedef ReportFileShare =
    Future<void> Function(
      File file,
      String mimeType, {
      String? fileName,
      List<String> preferredPackages,
    });

typedef ReportTextShare =
    Future<void> Function(
      String text, {
      List<String> preferredPackages,
      String? chooserTitle,
    });

/// Runs heavy work off the UI isolate. The default is [Isolate.run]; tests use
/// an inline runner because a real isolate never finishes under fake time.
typedef ReportTaskRunner = Future<T> Function<T>(FutureOr<T> Function() task);

Future<T> _inlineTask<T>(FutureOr<T> Function() task) async => task();

/// A [ReportTaskRunner] that computes on the calling isolate.
const ReportTaskRunner inlineReportTaskRunner = _inlineTask;

Future<T> _isolateTask<T>(FutureOr<T> Function() task) => Isolate.run(task);

/// Writes reports to a private temporary folder, shares the file and deletes
/// it again, whether or not the share worked.
final class SharingReportExporter implements ReportExporter {
  SharingReportExporter({
    required this._temporaryDirectory,
    required this._loadFonts,
    required this._shareFile,
    required this._shareText,
    required this._saveFile,
    required this._printFile,
    required List<String> whatsAppPackages,
    ReportTaskRunner? runTask,
    this._textBuilder = const ReportTextBuilder(),
    this._labels = _standardLabels,
    String Function()? nextId,
  }) : _whatsAppPackages = List.unmodifiable(whatsAppPackages),
       _runTask = runTask ?? _isolateTask,
       _nextId = nextId ?? _timeId;

  /// Start of the name of every temporary report file. The startup cleanup of
  /// the encrypted-file storage removes leftovers by this prefix.
  static const temporaryPrefix = 'jibi-doc-report-';

  final Directory _temporaryDirectory;
  final Future<ReportFonts> Function() _loadFonts;
  final ReportFileShare _shareFile;
  final ReportTextShare _shareText;
  final ReportFileSave _saveFile;
  final ReportFilePrint _printFile;
  final List<String> _whatsAppPackages;
  final ReportTaskRunner _runTask;
  final ReportTextBuilder _textBuilder;

  /// The wording of the two sides, read when a file is built so it follows the
  /// current settings.
  final BookLabels Function() _labels;
  final String Function() _nextId;

  Future<ReportFonts>? _fonts;

  static String _timeId() => DateTime.now().microsecondsSinceEpoch.toString();

  static BookLabels _standardLabels() => BookLabels.standard;

  /// The name a saved or shared file gets (without its extension).
  static String _displayName(ReportDocument document) =>
      '${document.fileBaseName} ${_fileStamp(document.generatedAt)}';

  /// Builds the file of [document], hands it to [use] and always deletes it
  /// again, whatever [use] did. Failures are reported as one readable error.
  Future<T> _withTemporaryFile<T>(
    ReportDocument document,
    ReportFormat format,
    Future<T> Function(File file) use,
  ) async {
    File? file;
    try {
      final bytes = await _build(document, format);
      await _temporaryDirectory.create(recursive: true);
      file = File(
        '${_temporaryDirectory.path}${Platform.pathSeparator}'
        '$temporaryPrefix${_nextId()}.${format.extension}',
      );
      await file.writeAsBytes(bytes, flush: true);
      return await use(file);
    } on AppException {
      rethrow;
    } on Object catch (error) {
      throw StorageException(
        code: 'report_export_failed',
        userMessage: 'تعذر إنشاء ملف التقرير. حاول مرة أخرى.',
        cause: error,
      );
    } finally {
      await _deleteQuietly(file);
    }
  }

  @override
  Future<void> shareFile(
    ReportDocument document,
    ReportFormat format, {
    ReportShareTarget target = ReportShareTarget.chooser,
  }) => _withTemporaryFile(
    document,
    format,
    (file) => _shareFile(
      file,
      format.mimeType,
      fileName: _displayName(document),
      preferredPackages: _packagesFor(target),
    ),
  );

  @override
  Future<bool> saveFile(ReportDocument document, ReportFormat format) =>
      _withTemporaryFile(
        document,
        format,
        (file) => _saveFile(
          file,
          format.mimeType,
          fileName: '${_displayName(document)}.${format.extension}',
        ),
      );

  @override
  Future<void> printDocument(ReportDocument document) => _withTemporaryFile(
    document,
    ReportFormat.pdf,
    (file) => _printFile(file, jobName: _displayName(document)),
  );

  @override
  Future<void> shareText(
    ReportDocument document, {
    ReportShareTarget target = ReportShareTarget.chooser,
  }) async {
    try {
      await _shareText(
        _textBuilder.build(document),
        preferredPackages: _packagesFor(target),
        chooserTitle: 'مشاركة التقرير',
      );
    } on Object catch (error) {
      throw StorageException(
        code: 'report_share_failed',
        userMessage: 'تعذر مشاركة التقرير. حاول مرة أخرى.',
        cause: error,
      );
    }
  }

  List<String> _packagesFor(ReportShareTarget target) =>
      target == ReportShareTarget.whatsApp
      ? _whatsAppPackages
      : const <String>[];

  Future<Uint8List> _build(ReportDocument document, ReportFormat format) async {
    switch (format) {
      case ReportFormat.pdf:
        // Loaded once; the font files are a few dozen kilobytes.
        final fonts = await (_fonts ??= _loadFonts());
        return _renderPdf(_runTask, document, fonts, _labels());
      case ReportFormat.xlsx:
        return _writeXlsx(_runTask, document, _labels());
    }
  }

  // Static so the closure sent to the isolate captures nothing but the
  // document, the fonts and the labels (plain data), never this exporter.
  static Future<Uint8List> _renderPdf(
    ReportTaskRunner run,
    ReportDocument document,
    ReportFonts fonts,
    BookLabels labels,
  ) => run(
    () => ReportPdfRenderer(fonts: fonts, labels: labels).render(document),
  );

  static Future<Uint8List> _writeXlsx(
    ReportTaskRunner run,
    ReportDocument document,
    BookLabels labels,
  ) => run(() => ReportXlsxWriter(labels: labels).write(document));

  static Future<void> _deleteQuietly(File? file) async {
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // The startup cleanup removes leftovers by their prefix.
    }
  }

  static String _fileStamp(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${value.year}${two(value.month)}${two(value.day)}-'
        '${two(value.hour)}${two(value.minute)}';
  }
}
