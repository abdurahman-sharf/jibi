import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';

import '../errors/app_exception.dart';
import '../models/document.dart';
import '../security/security_service.dart';

final class FileImportRequest {
  const FileImportRequest({
    required this.sourceFile,
    required this.originalExtension,
    required this.mimeType,
  });

  final File sourceFile;
  final String originalExtension;
  final String mimeType;
}

final class TemporaryFileHandle {
  const TemporaryFileHandle({required this.file, required this.delete});

  final File file;
  final Future<void> Function() delete;
}

/// Owns encrypted files in app-private storage, never source-path references.
abstract interface class SecureFileStorage {
  Future<DocumentFile> importFile({
    required String documentId,
    required FileImportRequest request,
  });
  Future<TemporaryFileHandle> openTemporaryFile(DocumentFile file);
  Future<void> deleteFile(DocumentFile file);
  Future<void> cleanupTemporaryFiles();
  Future<int> encryptedStorageSizeBytes();
}

typedef StorageIdGenerator = String Function();

/// Stores only ciphertext in a dedicated, app-private directory.
///
/// Both directories must be app-private. Temporary files are plaintext only for
/// the lifetime of a [TemporaryFileHandle] and must be deleted by its caller.
final class FileSystemSecureFileStorage implements SecureFileStorage {
  FileSystemSecureFileStorage({
    required Directory encryptedDirectory,
    required Directory temporaryDirectory,
    required SecurityService securityService,
    StorageIdGenerator? idGenerator,
    DateTime Function()? clock,
  }) : _encryptedDirectory = encryptedDirectory,
       _temporaryDirectory = temporaryDirectory,
       _securityService = securityService,
       _idGenerator = idGenerator ?? _defaultId,
       _clock = clock ?? DateTime.now;

  static const _temporaryPrefix = 'jibi-doc-';

  final Directory _encryptedDirectory;
  final Directory _temporaryDirectory;
  final SecurityService _securityService;
  final StorageIdGenerator _idGenerator;
  final DateTime Function() _clock;
  final Set<String> _temporaryPaths = <String>{};

  @override
  Future<DocumentFile> importFile({
    required String documentId,
    required FileImportRequest request,
  }) async {
    final extension = _normaliseExtension(request.originalExtension);
    await _encryptedDirectory.create(recursive: true);

    Uint8List plaintext;
    try {
      plaintext = await request.sourceFile.readAsBytes();
    } on Object catch (error) {
      throw StorageException(
        code: 'document_source_unreadable',
        userMessage: 'تعذر قراءة الملف المحدد.',
        cause: error,
      );
    }

    Uint8List ciphertext;
    try {
      ciphertext = await _securityService.encryptBytes(plaintext);
    } on Object catch (error) {
      throw SecurityException(
        code: 'document_file_encryption_failed',
        userMessage: 'تعذر تأمين الملف.',
        cause: error,
      );
    } finally {
      plaintext.fillRange(0, plaintext.length, 0);
    }

    final fileId = _nextSafeId();
    final encryptedFileName = '$fileId.enc';
    final target = _encryptedFile(encryptedFileName);
    final partial = File('${target.path}.partial');
    try {
      if (await target.exists()) {
        throw const StorageException(
          code: 'document_file_name_collision',
          userMessage: 'تعذر حفظ الملف. حاول مرة أخرى.',
        );
      }
      await partial.writeAsBytes(ciphertext, flush: true);
      await partial.rename(target.path);
      final checksum = await _ciphertextChecksum(ciphertext);
      return DocumentFile(
        id: fileId,
        documentId: documentId,
        encryptedFileName: encryptedFileName,
        originalExtension: extension,
        mimeType: request.mimeType,
        encryptedSizeBytes: ciphertext.length,
        checksum: checksum,
        createdAt: _clock().toUtc(),
      );
    } on AppException {
      rethrow;
    } on Object catch (error) {
      throw StorageException(
        code: 'document_file_write_failed',
        userMessage: 'تعذر حفظ الملف بأمان.',
        cause: error,
      );
    } finally {
      if (await partial.exists()) {
        await partial.delete();
      }
    }
  }

  @override
  Future<TemporaryFileHandle> openTemporaryFile(DocumentFile file) async {
    final encrypted = _encryptedFile(file.encryptedFileName);
    Uint8List ciphertext;
    try {
      ciphertext = await encrypted.readAsBytes();
    } on Object catch (error) {
      throw StorageException(
        code: 'encrypted_document_unreadable',
        userMessage: 'تعذر فتح الملف المحفوظ.',
        cause: error,
      );
    }

    Uint8List plaintext;
    try {
      plaintext = await _securityService.decryptBytes(ciphertext);
    } on Object catch (error) {
      throw SecurityException(
        code: 'document_file_decryption_failed',
        userMessage: 'تعذر فتح الملف بأمان.',
        cause: error,
      );
    }

    await _temporaryDirectory.create(recursive: true);
    final temporary = File(
      '${_temporaryDirectory.path}${Platform.pathSeparator}'
      '$_temporaryPrefix${_nextSafeId()}.${_normaliseExtension(file.originalExtension)}',
    );
    try {
      await temporary.writeAsBytes(plaintext, flush: true);
      _temporaryPaths.add(temporary.path);
    } on Object catch (error) {
      throw StorageException(
        code: 'temporary_document_write_failed',
        userMessage: 'تعذر تجهيز الملف للعرض.',
        cause: error,
      );
    } finally {
      plaintext.fillRange(0, plaintext.length, 0);
    }

    var deleted = false;
    return TemporaryFileHandle(
      file: temporary,
      delete: () async {
        if (deleted) {
          return;
        }
        deleted = true;
        _temporaryPaths.remove(temporary.path);
        if (await temporary.exists()) {
          await temporary.delete();
        }
      },
    );
  }

  @override
  Future<void> deleteFile(DocumentFile file) async {
    final encrypted = _encryptedFile(file.encryptedFileName);
    try {
      if (await encrypted.exists()) {
        await encrypted.delete();
      }
    } on Object catch (error) {
      throw StorageException(
        code: 'encrypted_document_delete_failed',
        userMessage: 'تعذر حذف الملف المحفوظ.',
        cause: error,
      );
    }
  }

  @override
  Future<void> cleanupTemporaryFiles() async {
    if (!await _temporaryDirectory.exists()) {
      return;
    }
    await for (final entity in _temporaryDirectory.list(followLinks: false)) {
      if (entity is File &&
          _leafName(entity.path).startsWith(_temporaryPrefix)) {
        await entity.delete();
        _temporaryPaths.remove(entity.path);
      }
    }
  }

  @override
  Future<int> encryptedStorageSizeBytes() async {
    if (!await _encryptedDirectory.exists()) {
      return 0;
    }
    var total = 0;
    await for (final entity in _encryptedDirectory.list(followLinks: false)) {
      if (entity is File && _leafName(entity.path).endsWith('.enc')) {
        total += await entity.length();
      }
    }
    return total;
  }

  File _encryptedFile(String fileName) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]*\.enc$').hasMatch(fileName)) {
      throw const StorageException(
        code: 'invalid_encrypted_document_name',
        userMessage: 'تعذر الوصول إلى الملف المحفوظ.',
      );
    }
    return File(
      '${_encryptedDirectory.path}${Platform.pathSeparator}$fileName',
    );
  }

  String _nextSafeId() {
    final id = _idGenerator();
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]*$').hasMatch(id)) {
      throw const StorageException(
        code: 'invalid_document_file_id',
        userMessage: 'تعذر إنشاء معرف آمن للملف.',
      );
    }
    return id;
  }

  String _normaliseExtension(String extension) {
    final normalized = extension.trim().replaceFirst(RegExp(r'^\.'), '');
    if (!RegExp(r'^[A-Za-z0-9]{1,16}$').hasMatch(normalized)) {
      throw const ValidationException(
        code: 'invalid_document_extension',
        userMessage: 'نوع الملف غير صالح.',
      );
    }
    return normalized.toLowerCase();
  }

  Future<String> _ciphertextChecksum(Uint8List ciphertext) async {
    final hash = await Sha256().hash(ciphertext);
    return hash.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  static String _leafName(String path) =>
      path.substring(path.lastIndexOf(RegExp(r'[\\/]')) + 1);

  static String _defaultId() => const Uuid().v4();
}
