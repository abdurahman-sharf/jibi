import 'dart:typed_data';

import '../errors/app_exception.dart';

/// Largest stored size of the logo, signature or stamp picture. The screens
/// shrink a picked image well below this before saving it.
const int maxProfileImageBytes = 400 * 1024;

const int _maxNameLength = 80;
const int _maxAddressLength = 160;
const int _maxPhoneLength = 30;
const int _maxEmailLength = 120;

/// Who the reports are issued by (المتطلبات 49–52): names, contact details and
/// the three pictures shown on a report. Lives in the settings table, so it is
/// part of every backup and of a restore.
final class UserProfile {
  const UserProfile({
    this.nameAr,
    this.nameEn,
    this.addressAr,
    this.addressEn,
    this.phone,
    this.email,
    this.logo,
    this.signature,
    this.stamp,
    this.showLogo = true,
    this.showSignature = true,
    this.showStamp = true,
  });

  static const empty = UserProfile();

  /// Trims every text (blank becomes null) and checks lengths and formats.
  /// Throws [ValidationException] with an Arabic message.
  factory UserProfile.validated({
    String? nameAr,
    String? nameEn,
    String? addressAr,
    String? addressEn,
    String? phone,
    String? email,
    Uint8List? logo,
    Uint8List? signature,
    Uint8List? stamp,
    bool showLogo = true,
    bool showSignature = true,
    bool showStamp = true,
  }) {
    String? text(String? value, int max, String field) {
      final trimmed = value?.trim();
      if (trimmed == null || trimmed.isEmpty) return null;
      if (trimmed.length > max) {
        throw ValidationException(
          code: 'profile_field_too_long',
          userMessage: '$field يجب ألا يتجاوز $max حرفاً.',
        );
      }
      return trimmed;
    }

    final cleanPhone = text(phone, _maxPhoneLength, 'رقم الهاتف');
    if (cleanPhone != null && !RegExp(r'^[0-9+\-\s()٠-٩]+$').hasMatch(cleanPhone)) {
      throw const ValidationException(
        code: 'invalid_phone',
        userMessage: 'رقم الهاتف يقبل الأرقام والرمز + والشرطة فقط.',
      );
    }
    final cleanEmail = text(email, _maxEmailLength, 'البريد الإلكتروني');
    if (cleanEmail != null &&
        !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(cleanEmail)) {
      throw const ValidationException(
        code: 'invalid_email',
        userMessage: 'صيغة البريد الإلكتروني غير صحيحة.',
      );
    }
    for (final image in [logo, signature, stamp]) {
      if (image != null && image.length > maxProfileImageBytes) {
        throw const ValidationException(
          code: 'profile_image_too_large',
          userMessage: 'الصورة كبيرة جداً. اختر صورة أصغر.',
        );
      }
    }
    return UserProfile(
      nameAr: text(nameAr, _maxNameLength, 'الاسم العربي'),
      nameEn: text(nameEn, _maxNameLength, 'الاسم الإنجليزي'),
      addressAr: text(addressAr, _maxAddressLength, 'العنوان العربي'),
      addressEn: text(addressEn, _maxAddressLength, 'العنوان الإنجليزي'),
      phone: cleanPhone,
      email: cleanEmail,
      logo: logo,
      signature: signature,
      stamp: stamp,
      showLogo: showLogo,
      showSignature: showSignature,
      showStamp: showStamp,
    );
  }

  final String? nameAr;
  final String? nameEn;
  final String? addressAr;
  final String? addressEn;
  final String? phone;
  final String? email;

  /// PNG or JPEG bytes, already shrunk.
  final Uint8List? logo;
  final Uint8List? signature;
  final Uint8List? stamp;

  /// Whether each picture is printed on reports.
  final bool showLogo;
  final bool showSignature;
  final bool showStamp;

  /// Nothing to print on a report.
  bool get isBlank =>
      nameAr == null &&
      nameEn == null &&
      addressAr == null &&
      addressEn == null &&
      phone == null &&
      email == null &&
      logo == null &&
      signature == null &&
      stamp == null;

  /// The name to show in a short place: Arabic first.
  String? get displayName => nameAr ?? nameEn;
}
