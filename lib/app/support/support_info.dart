import '../../core/app_info.dart';

/// How to reach the developer. The phone number is kept out of every screen
/// on purpose: the buttons open WhatsApp and the dialer with it.
abstract final class SupportContact {
  /// Email addresses are case-insensitive; lower case reads better.
  static const String email = 'abdurahmansharf@gmail.com';

  /// International format without the plus sign (the form `wa.me` wants).
  static const String phone = '966530882752';

  static final Uri website = Uri.parse('https://alaw9l.com/');

  /// What the website card shows.
  static const String websiteLabel = 'alaw9l.com';

  /// The chat opens with this typed in. It names the app and its version and
  /// nothing else; the user can edit it before sending.
  static String whatsAppMessage() =>
      'السلام عليكم، أحتاج إلى دعم فني في تطبيق جيبي.\n'
      'الإصدار: ${AppInfo.display}\n'
      'وصف المشكلة أو الاقتراح: ';

  static String emailSubject() => 'طلب دعم فني - جيبي ${AppInfo.version}';

  static String emailBody() =>
      'السلام عليكم،\n\n'
      'أحتاج إلى دعم فني في تطبيق جيبي.\n'
      'الإصدار: ${AppInfo.display}\n\n'
      'وصف المشكلة أو الاقتراح:\n';
}
