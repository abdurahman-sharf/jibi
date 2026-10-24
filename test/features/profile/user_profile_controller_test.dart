import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/core/errors/app_exception.dart';
import 'package:jibi/core/models/models.dart';
import 'package:jibi/core/repositories/repositories.dart';
import 'package:jibi/features/profile/user_profile_controller.dart';

final class _MemoryProfiles implements UserProfileRepository {
  UserProfile stored = UserProfile.empty;
  int reads = 0;
  int saves = 0;

  @override
  Future<UserProfile> readUserProfile() async {
    reads++;
    return stored;
  }

  @override
  Future<void> saveUserProfile(UserProfile profile) async {
    saves++;
    stored = profile;
  }
}

void main() {
  late _MemoryProfiles repository;
  late List<int> requestedSides;
  Object? shrinkFailure;
  late Uint8List shrunk;
  late UserProfileController controller;

  setUp(() {
    repository = _MemoryProfiles();
    requestedSides = [];
    shrinkFailure = null;
    shrunk = Uint8List.fromList([1, 2, 3]);
    controller = UserProfileController(
      repository: repository,
      shrinkImage: (source, {required maxSide}) async {
        requestedSides.add(maxSide);
        final failure = shrinkFailure;
        if (failure != null) throw failure;
        return shrunk;
      },
    );
  });

  tearDown(() => controller.dispose());

  test('starts empty and loads the stored profile once', () async {
    repository.stored = UserProfile.validated(nameAr: 'أنا');
    expect(controller.current.isBlank, isTrue);

    final loaded = await controller.load();
    await controller.load();

    expect(loaded.nameAr, 'أنا');
    expect(controller.current.nameAr, 'أنا');
    expect(repository.reads, 1);
  });

  test('saving stores the profile and tells the listeners', () async {
    final seen = <String?>[];
    controller.listenable.addListener(
      () => seen.add(controller.current.nameAr),
    );

    await controller.save(UserProfile.validated(nameAr: 'الجديد'));

    expect(repository.stored.nameAr, 'الجديد');
    expect(controller.current.nameAr, 'الجديد');
    expect(seen, ['الجديد']);
  });

  test('a failed save leaves the current profile alone', () async {
    await controller.save(UserProfile.validated(nameAr: 'الأول'));
    final failing = UserProfileController(
      repository: _FailingProfiles(),
      shrinkImage: (source, {required maxSide}) async => source,
    );
    addTearDown(failing.dispose);

    await expectLater(
      failing.save(UserProfile.validated(nameAr: 'الثاني')),
      throwsA(isA<StateError>()),
    );
    expect(failing.current.isBlank, isTrue);
    expect(controller.current.nameAr, 'الأول');
  });

  test('reload picks up what a restore put in the database', () async {
    await controller.load();
    repository.stored = UserProfile.validated(nameAr: 'من نسخة');

    await controller.reload();

    expect(controller.current.nameAr, 'من نسخة');
  });

  group('prepareImage', () {
    test('asks for the size of each picture', () async {
      final bytes = Uint8List.fromList([9, 9, 9]);

      await controller.prepareImage(bytes, ProfileImageSlot.logo);
      await controller.prepareImage(bytes, ProfileImageSlot.signature);
      await controller.prepareImage(bytes, ProfileImageSlot.stamp);

      expect(requestedSides, [512, 600, 512]);
    });

    test('returns what the shrinker made', () async {
      final result = await controller.prepareImage(
        Uint8List.fromList([9]),
        ProfileImageSlot.logo,
      );

      expect(result, shrunk);
    });

    test('an empty file is refused', () async {
      await expectLater(
        controller.prepareImage(Uint8List(0), ProfileImageSlot.logo),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.code,
            'code',
            'profile_image_empty',
          ),
        ),
      );
      expect(requestedSides, isEmpty);
    });

    test('a file that is not a picture becomes a readable message', () async {
      shrinkFailure = const FormatException('not an image');

      await expectLater(
        controller.prepareImage(Uint8List.fromList([1]), ProfileImageSlot.logo),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.userMessage,
            'message',
            contains('تعذر قراءة الصورة'),
          ),
        ),
      );
    });

    test('a picture that stays too big is refused', () async {
      shrunk = Uint8List(maxProfileImageBytes + 1);

      await expectLater(
        controller.prepareImage(Uint8List.fromList([1]), ProfileImageSlot.stamp),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.code,
            'code',
            'profile_image_too_large',
          ),
        ),
      );
    });
  });
}

final class _FailingProfiles implements UserProfileRepository {
  @override
  Future<UserProfile> readUserProfile() async => UserProfile.empty;

  @override
  Future<void> saveUserProfile(UserProfile profile) =>
      Future<void>.error(StateError('disk full'));
}
