import 'dart:io';

import '../../core/errors/app_exception.dart';
import '../../core/models/attachment_ref.dart';
import '../../core/models/document.dart';
import '../../core/models/encrypted_value.dart';
import '../../core/repositories/repositories.dart';
import '../../core/security/pin_attempt_limiter.dart';
import '../../core/security/security_service.dart';
import '../../core/storage/secure_file_storage.dart';
import 'models/document_draft.dart';

/// Coordinates encryption, document persistence, encrypted file storage, and
/// attachment deletion policy without exposing cleartext metadata to a repo.
final class DocumentsController {
  DocumentsController({
    required DocumentsRepository repository,
    required SecureFileStorage fileStorage,
    required SecurityService securityService,
    required String Function() idGenerator,
    DateTime Function()? clock,
  }) : _repository = repository,
       _fileStorage = fileStorage,
       _securityService = securityService,
       _idGenerator = idGenerator,
       _clock = clock ?? DateTime.now;

  final DocumentsRepository _repository;
  final SecureFileStorage _fileStorage;
  final SecurityService _securityService;
  final String Function() _idGenerator;
  final DateTime Function() _clock;

  Stream<List<Document>> watchDocuments({String? query, String? categoryId}) =>
      _repository.watchDocuments(query: query, categoryId: categoryId);

  Future<Document?> findDocument(String id) => _repository.findDocument(id);

  /// True when [pin] is right. Throws a `SecurityException` while PIN
  /// attempts are paused after too many wrong ones.
  Future<bool> authorizeSharing(String pin) async {
    final result = await _securityService.unlockWithPin(pin);
    final retryAfter = result.retryAfter;
    if (result.reason == 'pin_locked_out' && retryAfter != null) {
      throw SecurityException(
        code: 'pin_locked_out',
        userMessage: pinLockoutMessage(retryAfter),
      );
    }
    return result.authenticated;
  }

  Future<Map<String, String>> readDetails(Document document) async {
    final result = <String, String>{};
    for (final field in {
      'رقم المستند': document.documentNumberEncrypted,
      'جهة الإصدار': document.issuerEncrypted,
      'ملاحظات': document.notesEncrypted,
    }.entries) {
      if (field.value != null) {
        result[field.key] = await _securityService.decryptText(field.value!);
      }
    }
    return result;
  }

  Future<List<DocumentFile>> listFiles(String documentId) =>
      _repository.listFiles(documentId);

  Future<Document> createDocument(DocumentDraft draft) async {
    final now = _clock().toUtc();
    final document = await _toDocument(
      id: _idGenerator(),
      draft: draft,
      createdAt: now,
      updatedAt: now,
    );
    await _repository.saveDocument(document);
    return document;
  }

  Future<Document> updateDocument(String id, DocumentDraft draft) async {
    final existing = await _repository.findDocument(id);
    if (existing == null) {
      throw const NotFoundException(
        code: 'document_not_found',
        userMessage: 'المستند المطلوب غير موجود.',
      );
    }
    final document = await _toDocument(
      id: existing.id,
      draft: draft,
      createdAt: existing.createdAt,
      updatedAt: _clock().toUtc(),
    );
    await _repository.saveDocument(document);
    return document;
  }

  /// Rolls back a newly created document if any selected attachment fails.
  Future<Document> createWithFiles(
    DocumentDraft draft,
    List<FileImportRequest> requests,
  ) async {
    final document = await createDocument(draft);
    try {
      for (final request in requests) {
        await importFile(documentId: document.id, request: request);
      }
      return document;
    } on Object {
      await deleteDocument(document.id);
      rethrow;
    }
  }

  Future<DocumentFile> importFile({
    required String documentId,
    required FileImportRequest request,
  }) async {
    final document = await _repository.findDocument(documentId);
    if (document == null) {
      throw const NotFoundException(
        code: 'document_not_found',
        userMessage: 'المستند المطلوب غير موجود.',
      );
    }

    final file = await _fileStorage.importFile(
      documentId: document.id,
      request: request,
    );
    try {
      await _repository.saveDocumentFile(file);
      return file;
    } on Object {
      await _fileStorage.deleteFile(file);
      rethrow;
    }
  }

  Future<void> deleteDocumentFile(DocumentFile file) async {
    await _assertFileIsUnattached(file);
    await _fileStorage.deleteFile(file);
    await _repository.deleteDocumentFile(file.id);
  }

  Future<void> deleteDocument(String id) async {
    final document = await _repository.findDocument(id);
    if (document == null) {
      throw const NotFoundException(
        code: 'document_not_found',
        userMessage: 'المستند المطلوب غير موجود.',
      );
    }
    final files = await _repository.listFiles(document.id);
    for (final file in files) {
      await _assertFileIsUnattached(file);
    }
    for (final file in files) {
      await _fileStorage.deleteFile(file);
      await _repository.deleteDocumentFile(file.id);
    }
    await _repository.deleteDocument(document.id);
  }

  Future<void> addAttachmentReference(AttachmentRef reference) =>
      _repository.addAttachmentReference(reference);

  Future<void> removeAttachmentReference(String referenceId) =>
      _repository.removeAttachmentReference(referenceId);

  /// Gives a consumer a decrypted file and deletes it even if that consumer
  /// fails, such as when a platform viewer or share handoff throws.
  Future<T> withTemporaryFile<T>(
    DocumentFile file,
    Future<T> Function(File temporaryFile) action,
  ) async {
    final handle = await _fileStorage.openTemporaryFile(file);
    try {
      return await action(handle.file);
    } finally {
      await handle.delete();
    }
  }

  Future<Document> _toDocument({
    required String id,
    required DocumentDraft draft,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) async {
    return Document(
      id: id,
      title: draft.title,
      categoryId: draft.categoryId,
      documentNumberEncrypted: await _encryptOptional(draft.documentNumber),
      issuerEncrypted: await _encryptOptional(draft.issuer),
      issueDate: draft.issueDate?.toUtc(),
      expiryDate: draft.expiryDate?.toUtc(),
      notesEncrypted: await _encryptOptional(draft.notes),
      tagIds: draft.tagIds,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  Future<EncryptedValue?> _encryptOptional(String? plaintext) async {
    if (plaintext == null) {
      return null;
    }
    try {
      return await _securityService.encryptText(plaintext);
    } on Object catch (error) {
      throw SecurityException(
        code: 'document_metadata_encryption_failed',
        userMessage: 'تعذر تأمين بيانات المستند.',
        cause: error,
      );
    }
  }

  Future<void> _assertFileIsUnattached(DocumentFile file) async {
    final references = await _repository.listAttachmentReferences(file.id);
    if (references.isNotEmpty) {
      throw const ConflictException(
        code: 'document_file_is_attached',
        userMessage: 'لا يمكن حذف ملف مرتبط بسجل آخر.',
      );
    }
  }
}
