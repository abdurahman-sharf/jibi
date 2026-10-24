import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jibi/core/errors/app_exception.dart';
import 'package:jibi/core/models/attachment_ref.dart';
import 'package:jibi/core/models/document.dart';
import 'package:jibi/core/models/encrypted_value.dart';
import 'package:jibi/core/repositories/repositories.dart';
import 'package:jibi/core/security/security_service.dart';
import 'package:jibi/core/storage/secure_file_storage.dart';
import 'package:jibi/features/documents/documents_controller.dart';
import 'package:jibi/features/documents/models/document_draft.dart';

void main() {
  group('authorizeSharing', () {
    DocumentsController controllerWith(_FakeSecurityService security) =>
        DocumentsController(
          repository: _FakeDocumentsRepository(),
          fileStorage: _FakeFileStorage(),
          securityService: security,
          idGenerator: () => 'id',
        );

    test('accepts the right PIN', () async {
      final security = _FakeSecurityService()
        ..unlockResult = const AuthenticationResult(authenticated: true);

      expect(await controllerWith(security).authorizeSharing('123456'), isTrue);
    });

    test('refuses a wrong PIN', () async {
      final security = _FakeSecurityService()
        ..unlockResult = const AuthenticationResult(
          authenticated: false,
          reason: 'invalid_pin',
        );

      expect(await controllerWith(security).authorizeSharing('000000'), isFalse);
    });

    test('says how long to wait while PIN attempts are paused', () async {
      final security = _FakeSecurityService()
        ..unlockResult = const AuthenticationResult(
          authenticated: false,
          reason: 'pin_locked_out',
          retryAfter: Duration(minutes: 5),
        );

      await expectLater(
        controllerWith(security).authorizeSharing('123456'),
        throwsA(
          isA<SecurityException>()
              .having((error) => error.code, 'code', 'pin_locked_out')
              .having(
                (error) => error.userMessage,
                'message',
                contains('5 دقائق'),
              ),
        ),
      );
    });
  });

  test(
    'failed attachment import rolls back the new document and prior files',
    () async {
      final repository = _FakeDocumentsRepository();
      final storage = _FakeFileStorage()..failOnSecondImport = true;
      final controller = DocumentsController(
        repository: repository,
        fileStorage: storage,
        securityService: _FakeSecurityService(),
        idGenerator: () => 'new-document',
      );
      final request = FileImportRequest(
        sourceFile: File('unused'),
        originalExtension: 'pdf',
        mimeType: 'application/pdf',
      );
      await expectLater(
        controller.createWithFiles(DocumentDraft(title: 'Test'), [
          request,
          request,
        ]),
        throwsStateError,
      );
      expect(repository.documents, isEmpty);
      expect(repository.files, isEmpty);
      expect(storage.deletedFiles, ['file-id']);
    },
  );

  test('encrypts sensitive metadata before saving document records', () async {
    final repository = _FakeDocumentsRepository();
    final security = _FakeSecurityService();
    final controller = DocumentsController(
      repository: repository,
      fileStorage: _FakeFileStorage(),
      securityService: security,
      idGenerator: () => 'document-id',
      clock: () => DateTime.utc(2026, 1, 1),
    );

    final document = await controller.createDocument(
      DocumentDraft(
        title: 'Passport',
        documentNumber: 'P12345678',
        issuer: 'Authority',
        notes: 'private note',
      ),
    );

    expect(security.encryptedTexts, <String>[
      'P12345678',
      'Authority',
      'private note',
    ]);
    expect(repository.savedDocuments, hasLength(1));
    final stored = repository.savedDocuments.single;
    expect(stored, same(document));
    expect(stored.documentNumberEncrypted!.value, 'ciphertext-1');
    expect(stored.issuerEncrypted!.value, 'ciphertext-2');
    expect(stored.notesEncrypted!.value, 'ciphertext-3');
    expect(stored.documentNumberEncrypted, isA<EncryptedValue>());
  });

  test(
    'prevents attached file deletion and deletes unreferenced file lifecycle',
    () async {
      final repository = _FakeDocumentsRepository();
      final storage = _FakeFileStorage();
      final controller = DocumentsController(
        repository: repository,
        fileStorage: storage,
        securityService: _FakeSecurityService(),
        idGenerator: () => 'document-id',
        clock: () => DateTime.utc(2026, 1, 1),
      );
      await controller.createDocument(DocumentDraft(title: 'Identity'));
      final file = await controller.importFile(
        documentId: 'document-id',
        request: FileImportRequest(
          sourceFile: File('unused'),
          originalExtension: 'pdf',
          mimeType: 'application/pdf',
        ),
      );
      repository.references[file.id] = <AttachmentRef>[
        AttachmentRef(
          id: 'reference-id',
          ownerType: AttachmentOwnerType.expense,
          ownerId: 'expense-id',
          documentFileId: file.id,
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      ];

      await expectLater(
        controller.deleteDocument('document-id'),
        throwsA(isA<ConflictException>()),
      );
      expect(storage.deletedFiles, isEmpty);

      repository.references.clear();
      await controller.deleteDocument('document-id');
      expect(storage.deletedFiles, <String>[file.id]);
      expect(repository.documents, isEmpty);
      expect(repository.files, isEmpty);
    },
  );
}

final class _FakeDocumentsRepository implements DocumentsRepository {
  final Map<String, Document> documents = <String, Document>{};
  final Map<String, DocumentFile> files = <String, DocumentFile>{};
  final Map<String, List<AttachmentRef>> references =
      <String, List<AttachmentRef>>{};
  final List<Document> savedDocuments = <Document>[];

  @override
  Future<void> addAttachmentReference(AttachmentRef reference) async {
    references
        .putIfAbsent(reference.documentFileId, () => <AttachmentRef>[])
        .add(reference);
  }

  @override
  Future<void> deleteDocument(String id) async {
    documents.remove(id);
  }

  @override
  Future<void> deleteDocumentFile(String id) async {
    files.remove(id);
  }

  @override
  Future<Document?> findDocument(String id) async => documents[id];

  @override
  Future<List<AttachmentRef>> listAttachmentReferences(
    String documentFileId,
  ) async => List<AttachmentRef>.unmodifiable(
    references[documentFileId] ?? const <AttachmentRef>[],
  );

  @override
  Future<List<DocumentFile>> listFiles(String documentId) async =>
      files.values.where((file) => file.documentId == documentId).toList();

  @override
  Future<void> removeAttachmentReference(String referenceId) async {
    for (final refs in references.values) {
      refs.removeWhere((reference) => reference.id == referenceId);
    }
  }

  @override
  Future<void> saveDocument(Document document) async {
    documents[document.id] = document;
    savedDocuments.add(document);
  }

  @override
  Future<void> saveDocumentFile(DocumentFile file) async {
    files[file.id] = file;
  }

  @override
  Stream<List<Document>> watchDocuments({String? query, String? categoryId}) =>
      Stream<List<Document>>.value(documents.values.toList());
}

final class _FakeFileStorage implements SecureFileStorage {
  bool failOnSecondImport = false;
  int imports = 0;
  final List<String> deletedFiles = <String>[];

  @override
  Future<void> cleanupTemporaryFiles() async {}

  @override
  Future<void> deleteFile(DocumentFile file) async {
    deletedFiles.add(file.id);
  }

  @override
  Future<int> encryptedStorageSizeBytes() async => 0;

  @override
  Future<DocumentFile> importFile({
    required String documentId,
    required FileImportRequest request,
  }) async {
    imports++;
    if (failOnSecondImport && imports == 2) throw StateError('Import failed');
    return DocumentFile(
      id: 'file-id',
      documentId: documentId,
      encryptedFileName: 'file-id.enc',
      originalExtension: request.originalExtension,
      mimeType: request.mimeType,
      encryptedSizeBytes: 4,
      checksum: 'checksum',
      createdAt: DateTime.utc(2026, 1, 1),
    );
  }

  @override
  Future<TemporaryFileHandle> openTemporaryFile(DocumentFile file) =>
      throw UnimplementedError();
}

final class _FakeSecurityService implements SecurityService {
  final List<String> encryptedTexts = <String>[];
  AuthenticationResult unlockResult = const AuthenticationResult(
    authenticated: false,
  );

  @override
  Stream<AppLockState> get lockStates => const Stream<AppLockState>.empty();

  @override
  Future<AuthenticationResult> authenticateBiometrically() =>
      Future<AuthenticationResult>.value(
        const AuthenticationResult(authenticated: false),
      );

  @override
  Future<void> changePin({
    required String currentPin,
    required String newPin,
  }) async {}

  @override
  Future<void> completeRecoverySetup({required String pin}) async {}

  @override
  Future<Uint8List> decryptBytes(Uint8List ciphertext) async => Uint8List(0);

  @override
  Future<String> decryptText(EncryptedValue encrypted) async => '';

  @override
  Future<Uint8List> encryptBytes(Uint8List plaintext) async => Uint8List(0);

  @override
  Future<EncryptedValue> encryptText(String plaintext) async {
    encryptedTexts.add(plaintext);
    return EncryptedValue('ciphertext-${encryptedTexts.length}');
  }

  @override
  Future<bool> get isInitialized => Future<bool>.value(true);

  @override
  Future<bool> get isRecoverySetupPending => Future<bool>.value(false);

  @override
  Future<void> initialize({required String pin}) async {}

  @override
  Future<void> lock() async {}

  @override
  Future<AuthenticationResult> reauthenticate() =>
      Future<AuthenticationResult>.value(
        const AuthenticationResult(authenticated: false),
      );

  @override
  Future<void> restoreWrappedDataKey({
    required Uint8List wrappedKey,
    required String recoveryPassword,
  }) async {}

  @override
  Future<AuthenticationResult> unlockWithPin(String pin) =>
      Future<AuthenticationResult>.value(unlockResult);

  @override
  Future<bool> verifyPin(String pin) => Future<bool>.value(false);

  @override
  Future<Uint8List> wrapDataKeyForRecovery(String recoveryPassword) =>
      Future<Uint8List>.value(Uint8List(0));
}
