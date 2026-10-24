import 'dart:typed_data';

import 'package:jibi/core/security/security.dart';

/// In-memory stand-in for the platform key store, shared by the app-flow tests.
class MemoryKeys implements SecureKeyStore {
  final values = <String, Uint8List>{};
  @override
  Future<Uint8List?> read(String key) async => values[key];
  @override
  Future<void> write(String key, Uint8List value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// A device with no fingerprint enrolled: biometric prompts always fail.
class NoBiometrics implements BiometricAuthenticator {
  @override
  Future<bool> authenticate({required String reason}) async => false;

  @override
  Future<bool> canAuthenticate() async => false;
}
