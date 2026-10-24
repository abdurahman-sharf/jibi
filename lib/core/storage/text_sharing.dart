import 'package:flutter/services.dart';

/// Shares plain text through the Android share sheet.
final class AndroidTextSharing {
  const AndroidTextSharing();

  static const _channel = MethodChannel('com.jibi.jibi/file_sharing');

  /// [preferredPackages] (for example `whatsAppPackages`) are tried in order;
  /// when none is installed the system chooser is shown.
  Future<void> share(
    String text, {
    List<String> preferredPackages = const <String>[],
    String? chooserTitle,
  }) => _channel.invokeMethod<void>('shareText', {
    'text': text,
    if (preferredPackages.isNotEmpty) 'preferredPackages': preferredPackages,
    'chooserTitle': ?chooserTitle,
  });
}
