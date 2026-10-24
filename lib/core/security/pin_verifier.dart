import 'dart:typed_data';

import '../errors/app_exception.dart';
import 'kdf.dart';
import 'security_primitives.dart';

/// A salted PBKDF2 verifier. It contains no recoverable PIN material.
final class PinVerifier {
  PinVerifier._({
    required this.iterations,
    required Uint8List salt,
    required Uint8List hash,
  }) : salt = Uint8List.fromList(salt),
       hash = Uint8List.fromList(hash);

  static const int version = 1;
  static const int _saltLength = 16;
  static const int _hashLength = 32;
  static const int _iterations = 600000;

  final int iterations;
  final Uint8List salt;
  final Uint8List hash;

  static Future<PinVerifier> create(String pin) async {
    _validatePin(pin);
    final salt = secureRandomBytes(_saltLength);
    final hash = await _derive(pin: pin, salt: salt, iterations: _iterations);
    return PinVerifier._(iterations: _iterations, salt: salt, hash: hash);
  }

  Future<bool> verify(String pin) async {
    if (!PinPolicy.isValid(pin)) {
      return false;
    }
    final candidate = await _derive(
      pin: pin,
      salt: salt,
      iterations: iterations,
    );
    return constantTimeEquals(hash, candidate);
  }

  Uint8List toBytes() {
    final result = ByteData(1 + 4 + _saltLength + _hashLength);
    result.setUint8(0, version);
    result.setUint32(1, iterations, Endian.big);
    result.buffer.asUint8List(5, _saltLength).setAll(0, salt);
    result.buffer.asUint8List(5 + _saltLength, _hashLength).setAll(0, hash);
    return Uint8List.fromList(result.buffer.asUint8List());
  }

  static PinVerifier fromBytes(Uint8List encoded) {
    const totalLength = 1 + 4 + _saltLength + _hashLength;
    if (encoded.length != totalLength || encoded[0] != version) {
      throw const SecurityException(
        code: 'invalid_pin_verifier',
        userMessage: 'بيانات الحماية غير صالحة.',
      );
    }
    final data = ByteData.sublistView(encoded);
    final iterations = data.getUint32(1, Endian.big);
    if (iterations < 100000) {
      throw const SecurityException(
        code: 'weak_pin_verifier',
        userMessage: 'بيانات الحماية غير صالحة.',
      );
    }
    return PinVerifier._(
      iterations: iterations,
      salt: Uint8List.fromList(encoded.sublist(5, 5 + _saltLength)),
      hash: Uint8List.fromList(encoded.sublist(5 + _saltLength)),
    );
  }

  @override
  String toString() => 'PinVerifier([redacted])';

  static Future<Uint8List> _derive({
    required String pin,
    required Uint8List salt,
    required int iterations,
  }) async {
    return Kdf.pbkdf2Sha256(
      password: pin,
      salt: salt,
      iterations: iterations,
      bits: _hashLength * 8,
    );
  }

  static void _validatePin(String pin) {
    if (!PinPolicy.isValid(pin)) {
      throw const ValidationException(
        code: 'invalid_pin',
        userMessage: 'رمز الدخول يجب أن يتكون من 6 أرقام على الأقل.',
      );
    }
  }

}
