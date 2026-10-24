import '../../../core/errors/app_exception.dart';
import '../../../core/models/model_validation.dart';

/// Cleartext editor input. It must be encrypted by [DocumentsController]
/// before crossing the repository boundary.
final class DocumentDraft {
  DocumentDraft({
    required String title,
    String? categoryId,
    String? documentNumber,
    String? issuer,
    this.issueDate,
    this.expiryDate,
    String? notes,
    List<String> tagIds = const <String>[],
  }) : title = requireText(title, 'document_title'),
       categoryId = _optionalId(categoryId, 'document_category_id'),
       documentNumber = _optionalText(documentNumber),
       issuer = _optionalText(issuer),
       notes = _optionalText(notes),
       tagIds = List<String>.unmodifiable(
         tagIds.map((tagId) => requireId(tagId, 'document_tag_id')),
       ) {
    if (issueDate != null &&
        expiryDate != null &&
        expiryDate!.isBefore(issueDate!)) {
      throw const ValidationException(
        code: 'invalid_document_dates',
        userMessage: 'تاريخ الانتهاء لا يمكن أن يسبق تاريخ الإصدار.',
      );
    }
  }

  final String title;
  final String? categoryId;
  final String? documentNumber;
  final String? issuer;
  final DateTime? issueDate;
  final DateTime? expiryDate;
  final String? notes;
  final List<String> tagIds;

  static String? _optionalText(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  static String? _optionalId(String? value, String field) {
    return value == null ? null : requireId(value, field);
  }
}
