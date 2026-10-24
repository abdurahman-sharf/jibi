import 'dart:io';
import 'dart:typed_data';

import 'package:jibi/core/models/document.dart';
import 'package:jibi/core/storage/document_source_picker.dart';
import 'package:jibi/core/storage/secure_file_storage.dart';

/// An in-memory [SecureFileStorage]. All file access is synchronous so widget
/// tests that run under fake time never wait on real I/O.
final class FakeSecureFileStorage implements SecureFileStorage {
  FakeSecureFileStorage(this.temporaryDirectory);

  final Directory temporaryDirectory;
  final Map<String, Uint8List> stored = <String, Uint8List>{};
  final List<TemporaryFileHandle> openedHandles = [];
  int _counter = 0;

  @override
  Future<DocumentFile> importFile({
    required String documentId,
    required FileImportRequest request,
  }) async {
    final bytes = request.sourceFile.readAsBytesSync();
    final name = 'fake-${++_counter}.enc';
    stored[name] = bytes;
    return DocumentFile(
      id: 'file-$_counter',
      documentId: documentId,
      encryptedFileName: name,
      originalExtension: request.originalExtension,
      mimeType: request.mimeType,
      encryptedSizeBytes: bytes.length + 28,
      checksum: 'sha-$_counter',
      createdAt: DateTime.utc(2026),
    );
  }

  @override
  Future<TemporaryFileHandle> openTemporaryFile(DocumentFile file) async {
    final bytes = stored[file.encryptedFileName];
    if (bytes == null) {
      throw const FileSystemException('missing encrypted file');
    }
    temporaryDirectory.createSync(recursive: true);
    final plain = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}'
      'open-${openedHandles.length}.${file.originalExtension}',
    )..writeAsBytesSync(bytes);
    final handle = TemporaryFileHandle(
      file: plain,
      delete: () async {
        if (plain.existsSync()) plain.deleteSync();
      },
    );
    openedHandles.add(handle);
    return handle;
  }

  @override
  Future<void> deleteFile(DocumentFile file) async {
    stored.remove(file.encryptedFileName);
  }

  @override
  Future<void> cleanupTemporaryFiles() async {}

  @override
  Future<int> encryptedStorageSizeBytes() async =>
      stored.values.fold<int>(0, (sum, bytes) => sum + bytes.length);
}

/// A picker that hands out prepared results (or null for "cancelled").
final class FakeDocumentSourcePicker implements DocumentSourcePicker {
  final List<FileImportRequest?> pickResults = [];
  final List<FileImportRequest?> captureResults = [];
  int pickCalls = 0;
  int captureCalls = 0;

  @override
  Future<FileImportRequest?> pickFile() async {
    pickCalls++;
    return pickResults.isEmpty ? null : pickResults.removeAt(0);
  }

  @override
  Future<FileImportRequest?> captureImage() async {
    captureCalls++;
    return captureResults.isEmpty ? null : captureResults.removeAt(0);
  }
}
