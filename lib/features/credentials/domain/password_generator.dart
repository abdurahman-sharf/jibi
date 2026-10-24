import 'dart:math';

import '../../../core/errors/app_exception.dart';

final class PasswordGenerationOptions {
  const PasswordGenerationOptions({
    this.length = 16,
    this.includeUppercase = true,
    this.includeLowercase = true,
    this.includeNumbers = true,
    this.includeSymbols = true,
  });

  final int length;
  final bool includeUppercase;
  final bool includeLowercase;
  final bool includeNumbers;
  final bool includeSymbols;

  List<String> get selectedCharacterSets => [
    if (includeUppercase) _uppercase,
    if (includeLowercase) _lowercase,
    if (includeNumbers) _numbers,
    if (includeSymbols) _symbols,
  ];
}

final class PasswordGenerator {
  PasswordGenerator({Random? random}) : _random = random ?? Random.secure();

  final Random _random;

  String generate([
    PasswordGenerationOptions options = const PasswordGenerationOptions(),
  ]) {
    final characterSets = options.selectedCharacterSets;
    if (characterSets.isEmpty || options.length < characterSets.length) {
      throw const ValidationException(
        code: 'invalid_password_generation_options',
        userMessage: 'اختر مجموعة أحرف واحدة وطولاً مناسباً على الأقل.',
      );
    }
    if (options.length < 16) {
      throw const ValidationException(
        code: 'password_too_short',
        userMessage: 'طول كلمة المرور يجب ألا يقل عن 16 حرفاً.',
      );
    }

    final characters = <String>[
      for (final characterSet in characterSets) _pick(characterSet),
      for (var index = characterSets.length; index < options.length; index++)
        _pick(characterSets[_random.nextInt(characterSets.length)]),
    ];
    for (var index = characters.length - 1; index > 0; index--) {
      final swapIndex = _random.nextInt(index + 1);
      final swap = characters[index];
      characters[index] = characters[swapIndex];
      characters[swapIndex] = swap;
    }
    return characters.join();
  }

  String _pick(String values) => values[_random.nextInt(values.length)];
}

const _uppercase = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
const _lowercase = 'abcdefghijklmnopqrstuvwxyz';
const _numbers = '0123456789';
const _symbols = r'!@#$%^&*()-_=+[]{}:,.?';
