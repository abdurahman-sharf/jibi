import 'package:uuid/uuid.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/models/models.dart';
import '../../../core/repositories/book_repository.dart';
import '../../../core/storage/secure_file_storage.dart';

/// Attachments of a transaction: images, receipts, vouchers, PDFs.
///
/// Files are encrypted by [SecureFileStorage] and only their metadata is kept
/// in `book_attachments`. Attachments migrated from the legacy ledger point at
/// the document vault instead and are never deleted from here.
final class BookAttachmentsController {
  BookAttachmentsController({
    required BookRepository repository,
    required SecureFileStorage storage,
    String Function()? newId,
    DateTime Function()? clock,
  }) : _repository = repository,
       _storage = storage,
       _newId = newId ?? const Uuid().v4,
       _clock = clock ?? DateTime.now;

  final BookRepository _repository;
  final SecureFileStorage _storage;
  final String Function() _newId;
  final DateTime Function() _clock;

  /// The kind offered first for a file of [mimeType].
  static BookAttachmentKind kindFor(String mimeType) {
    if (mimeType.startsWith('image/')) return BookAttachmentKind.image;
    if (mimeType == 'application/pdf') return BookAttachmentKind.pdf;
    return BookAttachmentKind.document;
  }

  /// Encrypts [request] and attaches it to [transactionId].
  Future<BookAttachment> add({
    required String transactionId,
    required FileImportRequest request,
    BookAttachmentKind? kind,
    String? fileName,
  }) async {
    final transaction = await _repository.transaction(transactionId);
    if (transaction == null || transaction.isDeleted) {
      throw const NotFoundException(
        code: 'transaction_not_found',
        userMessage: 'العملية المطلوبة غير موجودة.',
      );
    }
    final attachmentId = _newId();
    final stored = await _storage.importFile(
      documentId: transactionId,
      request: request,
    );
    final name = fileName?.trim();
    final BookAttachment attachment;
    try {
      attachment = BookAttachment(
        id: attachmentId,
        transactionId: transactionId,
        kind: kind ?? kindFor(request.mimeType),
        fileName: name == null || name.isEmpty
            ? 'مرفق.${stored.originalExtension}'
            : name,
        mimeType: request.mimeType,
        encryptedFileName: stored.encryptedFileName,
        originalExtension: stored.originalExtension,
        fileSize: stored.encryptedSizeBytes,
        checksum: stored.checksum,
        createdAt: _clock().toUtc(),
      );
      await _repository.write((writer) async {
        await writer.putAttachment(attachment);
        await writer.audit(
          'transaction',
          transactionId,
          'attachment_added',
          details: attachment.fileName,
        );
      });
    } on Object {
      // Never leave an encrypted file that no row points at.
      await _storage.deleteFile(stored);
      rethrow;
    }
    return attachment;
  }

  Future<List<BookAttachment>> list(String transactionId) async =>
      (await _repository.transaction(transactionId))?.attachments ??
      const <BookAttachment>[];

  Future<void> remove(String attachmentId) async {
    final removed = await _repository.write((writer) async {
      final attachment = await writer.attachment(attachmentId);
      if (attachment == null) {
        throw const NotFoundException(
          code: 'attachment_not_found',
          userMessage: 'المرفق المطلوب غير موجود.',
        );
      }
      await writer.removeAttachment(attachmentId);
      await writer.audit(
        'transaction',
        attachment.transactionId,
        'attachment_removed',
        details: attachment.fileName,
      );
      return attachment;
    });
    final owned = _ownedFile(removed);
    if (owned != null) {
      await _storage.deleteFile(owned);
    }
  }

  /// Decrypts the attachment to a temporary file. The caller must call
  /// `delete` on the handle when finished.
  Future<TemporaryFileHandle> open(BookAttachment attachment) async {
    final file =
        _ownedFile(attachment) ??
        await _repository.legacyDocumentFile(attachment.documentFileId!);
    if (file == null) {
      throw const NotFoundException(
        code: 'attachment_file_missing',
        userMessage: 'تعذر العثور على ملف المرفق.',
      );
    }
    return _storage.openTemporaryFile(file);
  }

  DocumentFile? _ownedFile(BookAttachment attachment) {
    final name = attachment.encryptedFileName;
    if (name == null) return null;
    return DocumentFile(
      id: attachment.id,
      documentId: attachment.transactionId,
      encryptedFileName: name,
      originalExtension: attachment.originalExtension ?? 'bin',
      mimeType: attachment.mimeType,
      encryptedSizeBytes: attachment.fileSize,
      checksum: attachment.checksum!,
      createdAt: attachment.createdAt,
    );
  }
}
