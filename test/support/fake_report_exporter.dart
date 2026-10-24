import 'package:jibi/features/book/reports/report_exporter.dart';
import 'package:jibi/features/book/reports/report_models.dart';

/// Records what the report screens asked to share, without touching files or
/// the platform.
final class FakeReportExporter implements ReportExporter {
  /// One entry per call: `file:pdf:chooser`, `file:xlsx:whatsApp`,
  /// `text:whatsApp`...
  final List<String> calls = [];
  final List<ReportDocument> documents = [];

  /// When set, the next call throws it.
  Object? failure;

  @override
  Future<void> shareFile(
    ReportDocument document,
    ReportFormat format, {
    ReportShareTarget target = ReportShareTarget.chooser,
  }) async {
    calls.add('file:${format.name}:${target.name}');
    documents.add(document);
    final error = failure;
    if (error != null) throw error;
  }

  /// What the next [saveFile] returns (false = the user cancelled).
  bool saveResult = true;

  @override
  Future<bool> saveFile(ReportDocument document, ReportFormat format) async {
    calls.add('save:${format.name}');
    documents.add(document);
    final error = failure;
    if (error != null) throw error;
    return saveResult;
  }

  @override
  Future<void> printDocument(ReportDocument document) async {
    calls.add('print');
    documents.add(document);
    final error = failure;
    if (error != null) throw error;
  }

  @override
  Future<void> shareText(
    ReportDocument document, {
    ReportShareTarget target = ReportShareTarget.chooser,
  }) async {
    calls.add('text:${target.name}');
    documents.add(document);
    final error = failure;
    if (error != null) throw error;
  }
}
