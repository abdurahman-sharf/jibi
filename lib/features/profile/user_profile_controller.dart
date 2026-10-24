import 'package:flutter/foundation.dart';

import '../../core/errors/app_exception.dart';
import '../../core/models/models.dart';
import '../../core/repositories/repositories.dart';

/// Shrinks a picked picture to what a report needs. Injected so tests do not
/// need a real image codec.
typedef ProfileImageShrinker =
    Future<Uint8List> Function(Uint8List source, {required int maxSide});

/// Which of the three pictures of the profile.
enum ProfileImageSlot {
  logo(maxSide: 512),
  signature(maxSide: 600),
  stamp(maxSide: 512);

  const ProfileImageSlot({required this.maxSide});

  /// Longest side, in pixels, the stored picture may have.
  final int maxSide;
}

/// Reads and writes the user's profile (المتطلبات 49–52) and lets the screens
/// and the report builder follow it.
final class UserProfileController {
  UserProfileController({
    required this._repository,
    required this._shrinkImage,
  });

  final UserProfileRepository _repository;
  final ProfileImageShrinker _shrinkImage;
  final ValueNotifier<UserProfile> _profile = ValueNotifier(UserProfile.empty);
  bool _loaded = false;

  /// The current profile; screens listen to it.
  ValueListenable<UserProfile> get listenable => _profile;

  UserProfile get current => _profile.value;

  Future<UserProfile> load() async {
    if (!_loaded) {
      _profile.value = await _repository.readUserProfile();
      _loaded = true;
    }
    return _profile.value;
  }

  /// Re-reads the stored profile (after a restore replaced the database).
  Future<void> reload() async {
    _profile.value = await _repository.readUserProfile();
    _loaded = true;
  }

  Future<void> save(UserProfile profile) async {
    await _repository.saveUserProfile(profile);
    _profile.value = profile;
    _loaded = true;
  }

  /// Shrinks [source] for [slot]. Throws [ValidationException] when it is not
  /// a readable picture or cannot be made small enough.
  Future<Uint8List> prepareImage(Uint8List source, ProfileImageSlot slot) async {
    if (source.isEmpty) {
      throw const ValidationException(
        code: 'profile_image_empty',
        userMessage: 'الملف المحدد فارغ.',
      );
    }
    try {
      final shrunk = await _shrinkImage(source, maxSide: slot.maxSide);
      if (shrunk.length > maxProfileImageBytes) {
        throw const ValidationException(
          code: 'profile_image_too_large',
          userMessage: 'الصورة كبيرة جداً. اختر صورة أصغر.',
        );
      }
      return shrunk;
    } on AppException {
      rethrow;
    } on Object {
      throw const ValidationException(
        code: 'profile_image_invalid',
        userMessage: 'تعذر قراءة الصورة. اختر ملف صورة صالحاً (PNG أو JPG).',
      );
    }
  }

  void dispose() => _profile.dispose();
}
