import 'package:flutter/services.dart';

import '../storage/file_sharing.dart' show whatsAppPackages;

/// Opens other apps (WhatsApp, the dialer, mail, the browser) from Jibi.
///
/// Every method returns whether an app took the request: false means nothing
/// on the device can handle it (WhatsApp, a dialer or a mail app is missing),
/// which the caller reports to the user. A platform failure throws.
abstract interface class ExternalLinkLauncher {
  /// Opens a WhatsApp chat with [phone] (international digits, no `+`) and
  /// [message] already typed in.
  Future<bool> openWhatsApp({required String phone, required String message});

  /// Opens the dialer with [phone] filled in; the user presses call.
  Future<bool> dial(String phone);

  /// Opens a new mail with the fields filled in.
  Future<bool> composeEmail({
    required String to,
    required String subject,
    required String body,
  });

  /// Opens [url] (https) in the browser.
  Future<bool> openWebsite(Uri url);
}

/// The Android implementation: a small platform channel (`MainActivity`).
final class AndroidExternalLinkLauncher implements ExternalLinkLauncher {
  const AndroidExternalLinkLauncher();

  static const _channel = MethodChannel('com.jibi.jibi/external_links');

  /// The `wa.me` link for [phone] and [message]. The message is percent
  /// encoded with `%20` for spaces (`Uri.encodeQueryComponent` would use `+`,
  /// which WhatsApp shows as a plus sign).
  static String whatsAppLink(String phone, String message) =>
      'https://wa.me/$phone?text=${Uri.encodeComponent(message)}';

  @override
  Future<bool> openWhatsApp({required String phone, required String message}) =>
      _open('openWhatsApp', {
        'url': whatsAppLink(phone, message),
        'preferredPackages': whatsAppPackages,
      });

  @override
  Future<bool> dial(String phone) => _open('dial', {'phone': phone});

  @override
  Future<bool> composeEmail({
    required String to,
    required String subject,
    required String body,
  }) => _open('composeEmail', {'to': to, 'subject': subject, 'body': body});

  @override
  Future<bool> openWebsite(Uri url) => _open('openWebsite', {'url': '$url'});

  Future<bool> _open(String method, Map<String, Object?> arguments) async =>
      await _channel.invokeMethod<bool>(method, arguments) ?? false;
}
