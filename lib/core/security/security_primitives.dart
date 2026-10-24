import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../errors/app_exception.dart';
import 'kdf.dart';

/// Cryptographically secure random bytes (salts and nonces).
Uint8List secureRandomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256), growable: false),
  );
}

/// Compares two byte lists in a time that depends only on their length, so a
/// hash or key check does not leak how many leading bytes matched.
bool constantTimeEquals(List<int> left, List<int> right) {
  if (left.length != right.length) {
    return false;
  }
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

/// Stretches a password (the PIN) into an AES key with PBKDF2-HMAC-SHA256.
Future<SecretKey> deriveKeyFromSecret(
  String password,
  List<int> salt,
  int iterations,
) async => SecretKey(
  await Kdf.pbkdf2Sha256(
    password: password,
    salt: salt,
    iterations: iterations,
  ),
);

/// The one rule for the app PIN: six digits or more.
abstract final class PinPolicy {
  static final RegExp _pattern = RegExp(r'^\d{6,}$');

  static bool isValid(String pin) => _pattern.hasMatch(pin);
}

/// The backup password is the PIN, so it follows [PinPolicy].
void validateBackupPin(String password) {
  if (!PinPolicy.isValid(password)) {
    throw const ValidationException(
      code: 'invalid_backup_pin',
      userMessage: 'رمز PIN يجب أن يتكون من 6 أرقام على الأقل.',
    );
  }
}
