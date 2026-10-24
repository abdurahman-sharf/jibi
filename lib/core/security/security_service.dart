import 'dart:typed_data';

import '../models/encrypted_value.dart';

enum AppLockState { locked, unlocked }

final class AuthenticationResult {
  const AuthenticationResult({
    required this.authenticated,
    this.reason,
    this.retryAfter,
  });

  final bool authenticated;

  /// Why it failed: `not_initialized`, `invalid_pin`, `pin_locked_out` (too
  /// many wrong PINs, see [retryAfter]) or `biometric_rejected`.
  final String? reason;

  /// How long PIN attempts stay paused; set with `pin_locked_out`.
  final Duration? retryAfter;
}

/// Security boundary. Implementations must never persist keys, PINs, or clear
/// text values in SQLite, files, logs, or analytics.
abstract interface class SecurityService {
  Stream<AppLockState> get lockStates;
  Future<bool> get isInitialized;

  /// True only after recovery material has been restored and a new app PIN is
  /// still required before normal unlocking can resume.
  Future<bool> get isRecoverySetupPending;

  Future<void> initialize({required String pin});
  Future<void> completeRecoverySetup({required String pin});
  Future<AuthenticationResult> unlockWithPin(String pin);

  /// Read-only PIN verification used to confirm the current PIN before a
  /// sensitive action (for example deriving the backup secret). It must not
  /// change the lock state and must not expose recoverable PIN material.
  ///
  /// Throws a `SecurityException` with code `pin_locked_out` while PIN
  /// attempts are paused after too many wrong ones.
  Future<bool> verifyPin(String pin);

  Future<AuthenticationResult> authenticateBiometrically();
  Future<AuthenticationResult> reauthenticate();
  Future<void> changePin({required String currentPin, required String newPin});
  Future<void> lock();

  Future<EncryptedValue> encryptText(String plaintext);
  Future<String> decryptText(EncryptedValue encrypted);
  Future<Uint8List> encryptBytes(Uint8List plaintext);
  Future<Uint8List> decryptBytes(Uint8List ciphertext);

  /// Exports only a recovery-password-wrapped data encryption key.
  Future<Uint8List> wrapDataKeyForRecovery(String recoveryPassword);

  /// Imports a recovery-wrapped key on a fresh install. Call
  /// [completeRecoverySetup] with a new app PIN before treating the app as
  /// initialized.
  Future<void> restoreWrappedDataKey({
    required Uint8List wrappedKey,
    required String recoveryPassword,
  });
}

/// Optional capability of a [SecurityService]: replacing a forgotten app PIN
/// after the phone itself (fingerprint or screen lock) confirmed the person.
///
/// The PIN only guards the lock screen; the data key is random and stored
/// apart from it, so a reset never touches stored data.
abstract interface class DeviceVerifiedPinReset {
  /// Whether the phone can confirm the person right now.
  Future<bool> canVerifyDeviceIdentity();

  /// Step 1: shows the system prompt. On success a single [resetPin] is
  /// allowed for a few minutes; the app stays locked. Reasons on failure:
  /// `not_initialized`, `device_auth_unavailable`, `identity_not_confirmed`.
  Future<AuthenticationResult> verifyDeviceIdentity();

  /// Step 2: stores [newPin], clears the wrong-PIN pause and unlocks the app.
  /// Throws a `SecurityException` with code `pin_reset_not_authorized` unless
  /// step 1 succeeded moments ago.
  Future<void> resetPin({required String newPin});
}

/// Optional capability of a [SecurityService]: whether biometric unlock can be
/// performed on this device right now (hardware present and enrolled).
abstract interface class BiometricCapability {
  Future<bool> canUseBiometrics();
}
