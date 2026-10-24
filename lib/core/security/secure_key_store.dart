import 'dart:typed_data';

/// Adapter for a hardware-backed keystore or OS secure storage.
///
/// Production composition must provide an implementation backed by platform
/// secure storage. This package intentionally provides no persistent fallback.
abstract interface class SecureKeyStore {
  Future<Uint8List?> read(String key);
  Future<void> write(String key, Uint8List value);
  Future<void> delete(String key);
}

/// Adapter around an OS biometric prompt.
abstract interface class BiometricAuthenticator {
  Future<bool> authenticate({required String reason});

  /// Whether the device can perform a biometric check. Defaults to true so
  /// existing fakes keep working; production returns the real capability.
  Future<bool> canAuthenticate() => Future.value(true);
}

/// Optional capability of a [BiometricAuthenticator]: confirming the person
/// with the phone's own lock, which is a biometric when one is enrolled and
/// otherwise the screen-lock PIN, pattern or password. Used only to replace a
/// forgotten app PIN; every other check stays biometric-only.
abstract interface class DeviceIdentityVerifier {
  /// True when the phone has an enrolled biometric or a screen lock.
  Future<bool> canVerifyIdentity();

  /// Shows the system prompt. False for a cancelled or failed check.
  Future<bool> verifyIdentity({required String reason});
}
