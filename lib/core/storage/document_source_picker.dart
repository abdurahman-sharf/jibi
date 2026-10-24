import 'dart:io';

import 'package:flutter/services.dart';

import '../errors/app_exception.dart';
import 'secure_file_storage.dart';

/// Platform file selection boundary. Implementations must return a copy in
/// app-private cache rather than retaining an external content URI.
abstract interface class DocumentSourcePicker {
  Future<FileImportRequest?> pickFile();

  /// Takes a photo with the system camera app. Returns null when the user
  /// cancels. The photo is a plaintext cache file the caller must delete after
  /// importing it into encrypted storage.
  Future<FileImportRequest?> captureImage();
}

final class AndroidDocumentSourcePicker implements DocumentSourcePicker {
  const AndroidDocumentSourcePicker() : _channel = _defaultChannel;

  const AndroidDocumentSourcePicker.withChannel(this._channel);

  static const _defaultChannel = MethodChannel(
    'com.jibi.jibi/document_source_picker',
  );
  final MethodChannel _channel;

  @override
  Future<FileImportRequest?> pickFile() => _request(
    method: 'pickDocument',
    failureCode: 'document_picker_failed',
    failureMessage: 'تعذر اختيار الملف.',
  );

  @override
  Future<FileImportRequest?> captureImage() => _request(
    method: 'captureDocument',
    failureCode: 'document_capture_failed',
    failureMessage: 'تعذر التقاط الصورة.',
    unavailableCodes: const {
      'no_camera_app': 'لا يوجد تطبيق كاميرا على هذا الجهاز.',
    },
  );

  Future<FileImportRequest?> _request({
    required String method,
    required String failureCode,
    required String failureMessage,
    Map<String, String> unavailableCodes = const {},
  }) async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(method);
      if (result == null) {
        return null;
      }
      final path = result['path'] as String?;
      final extension = result['extension'] as String?;
      final mimeType = result['mimeType'] as String?;
      if (path == null || extension == null || mimeType == null) {
        throw const FormatException('Incomplete document picker result.');
      }
      final source = File(path);
      if (!await source.exists()) {
        throw const FileSystemException('Cached source missing.');
      }
      return FileImportRequest(
        sourceFile: source,
        originalExtension: extension,
        mimeType: mimeType,
      );
    } on PlatformException catch (error) {
      throw StorageException(
        code: failureCode,
        userMessage: unavailableCodes[error.code] ?? failureMessage,
        cause: error,
      );
    } on Object catch (error) {
      throw StorageException(
        code: 'invalid_document_picker_result',
        userMessage: 'تعذر تجهيز الملف المحدد.',
        cause: error,
      );
    }
  }
}
