import 'encrypted_value.dart';
import 'model_validation.dart';

final class Document {
  Document({
    required String id,
    required String title,
    this.categoryId,
    this.documentNumberEncrypted,
    this.issuerEncrypted,
    this.issueDate,
    this.expiryDate,
    this.notesEncrypted,
    List<String> tagIds = const <String>[],
    required this.createdAt,
    required DateTime updatedAt,
  }) : id = requireId(id, 'document_id'),
       title = requireText(title, 'document_title'),
       tagIds = List<String>.unmodifiable(tagIds),
       updatedAt = requireChronologicalDates(createdAt, updatedAt) {
    if (issueDate != null &&
        expiryDate != null &&
        expiryDate!.isBefore(issueDate!)) {
      throw ArgumentError('Document expiry cannot precede issue date.');
    }
  }

  final String id;
  final String title;
  final String? categoryId;

  /// Sensitive document fields are encrypted-only by contract.
  final EncryptedValue? documentNumberEncrypted;
  final EncryptedValue? issuerEncrypted;
  final DateTime? issueDate;
  final DateTime? expiryDate;
  final EncryptedValue? notesEncrypted;
  final List<String> tagIds;
  final DateTime createdAt;
  final DateTime updatedAt;
}

final class DocumentFile {
  DocumentFile({
    required String id,
    required String documentId,
    required String encryptedFileName,
    required String originalExtension,
    required String mimeType,
    required this.encryptedSizeBytes,
    required String checksum,
    required this.createdAt,
  }) : id = requireId(id, 'document_file_id'),
       documentId = requireId(documentId, 'document_id'),
       encryptedFileName = requireText(
         encryptedFileName,
         'encrypted_file_name',
       ),
       originalExtension = requireText(originalExtension, 'original_extension'),
       mimeType = requireText(mimeType, 'mime_type'),
       checksum = requireText(checksum, 'checksum') {
    if (encryptedSizeBytes < 0) {
      throw ArgumentError('Encrypted file size cannot be negative.');
    }
  }

  final String id;
  final String documentId;
  final String encryptedFileName;
  final String originalExtension;
  final String mimeType;
  final int encryptedSizeBytes;
  final String checksum;
  final DateTime createdAt;
}
