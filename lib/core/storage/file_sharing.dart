import 'dart:io';

import 'package:flutter/services.dart';

/// Package names of WhatsApp and WhatsApp Business, in the order to try.
const List<String> whatsAppPackages = <String>[
  'com.whatsapp',
  'com.whatsapp.w4b',
];

/// The platform copies the file before returning, so the source may be removed.
final class AndroidFileSharing {
  const AndroidFileSharing();

  static const _channel = MethodChannel('com.jibi.jibi/file_sharing');

  /// [fileName] (without extension) is the name the receiving app shows;
  /// without it a random one is used. [preferredPackages] are tried in order
  /// (for example [whatsAppPackages]) before the system chooser is shown.
  Future<void> share(
    File file,
    String mimeType, {
    String? fileName,
    List<String> preferredPackages = const <String>[],
  }) => _channel.invokeMethod<void>('shareFile', {
    'path': file.path,
    'mimeType': mimeType,
    'fileName': ?fileName,
    if (preferredPackages.isNotEmpty) 'preferredPackages': preferredPackages,
  });

  /// Lets the user pick where to keep [file] (the system "save as" screen) and
  /// copies it there. [fileName] is the whole name with its extension. Returns
  /// false when the user cancelled.
  Future<bool> save(File file, String mimeType, {required String fileName}) async =>
      await _channel.invokeMethod<bool>('saveFile', {
        'path': file.path,
        'mimeType': mimeType,
        'fileName': fileName,
      }) ??
      false;

  /// Opens the system print screen for the PDF [file]. The platform keeps its
  /// own copy for the print job, so the source may be removed at once.
  Future<void> printPdf(File file, {String? jobName}) =>
      _channel.invokeMethod<void>('printPdf', {
        'path': file.path,
        'jobName': ?jobName,
      });
}
