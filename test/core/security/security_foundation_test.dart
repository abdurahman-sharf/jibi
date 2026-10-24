import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jibi/core/errors/app_exception.dart';
import 'package:jibi/core/models/encrypted_value.dart';
import 'package:jibi/core/security/security.dart';

void main() {
  group('AesGcmSecurityService', () {
    test('rejects tampered AES-GCM ciphertext', () async {
      final service = await _initializedService();
      final encrypted = await service.encryptBytes(
        Uint8List.fromList([1, 2, 3]),
      );
      encrypted[encrypted.length - 1] ^= 1;

      expect(
        () => service.decryptBytes(encrypted),
        throwsA(
          isA<SecurityException>().having(
            (error) => error.code,
            'code',
            'ciphertext_authentication_failed',
          ),
        ),
      );
    });

    test('round-trips a PIN-wrapped data key on a fresh install', () async {
      final source = await _initializedService();
      final encrypted = await source.encryptText('vault content');
      final recoveryPassword = '123456';
      final wrapped = await source.wrapDataKeyForRecovery(recoveryPassword);

      final restored = AesGcmSecurityService(
        keyStore: _MemorySecureKeyStore(),
        biometricAuthenticator: const _BiometricResult(true),
      );
      await restored.restoreWrappedDataKey(
        wrappedKey: wrapped,
        recoveryPassword: recoveryPassword,
      );

      expect(await restored.isInitialized, isFalse);
      expect(await restored.isRecoverySetupPending, isTrue);
      expect(await restored.decryptText(encrypted), 'vault content');

      await restored.completeRecoverySetup(pin: '654321');
      await restored.lock();
      expect((await restored.unlockWithPin('654321')).authenticated, isTrue);
      expect(await restored.decryptText(encrypted), 'vault content');
    });

    test('stores a salted PIN verifier and never plaintext PIN', () async {
      final store = _MemorySecureKeyStore();
      final service = AesGcmSecurityService(
        keyStore: store,
        biometricAuthenticator: const _BiometricResult(true),
      );

      await service.initialize(pin: '123456');

      expect(
        store.values.values.map((value) => String.fromCharCodes(value)).join(),
        isNot(contains('123456')),
      );
      expect((await service.unlockWithPin('654321')).authenticated, isFalse);
      expect((await service.unlockWithPin('123456')).authenticated, isTrue);
    });
  });

  test('locks after the configured background session timeout', () async {
    final security = _LockTrackingSecurityService();
    var now = DateTime.utc(2026, 1, 1, 12);
    final controller = AppLockController(
      securityService: security,
      policy: const TimeoutAppLockPolicy(Duration(minutes: 5)),
      clock: () => now,
    );

    await controller.handle(AppLifecycleEvent.backgrounded);
    now = now.add(const Duration(minutes: 4, seconds: 59));
    await controller.handle(AppLifecycleEvent.foregrounded);
    expect(security.lockCount, 0);

    await controller.handle(AppLifecycleEvent.backgrounded);
    now = now.add(const Duration(minutes: 5));
    await controller.handle(AppLifecycleEvent.foregrounded);
    expect(security.lockCount, 1);
  });
}

Future<AesGcmSecurityService> _initializedService() async {
  final service = AesGcmSecurityService(
    keyStore: _MemorySecureKeyStore(),
    biometricAuthenticator: const _BiometricResult(true),
  );
  await service.initialize(pin: '123456');
  return service;
}

final class _MemorySecureKeyStore implements SecureKeyStore {
  final Map<String, Uint8List> values = {};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<Uint8List?> read(String key) async {
    final value = values[key];
    return value == null ? null : Uint8List.fromList(value);
  }

  @override
  Future<void> write(String key, Uint8List value) async {
    values[key] = Uint8List.fromList(value);
  }
}

final class _BiometricResult implements BiometricAuthenticator {
  const _BiometricResult(this.result);

  final bool result;

  @override
  Future<bool> authenticate({required String reason}) async => result;

  @override
  Future<bool> canAuthenticate() async => true;
}

final class _LockTrackingSecurityService implements SecurityService {
  final StreamController<AppLockState> _states =
      StreamController<AppLockState>.broadcast();
  int lockCount = 0;

  @override
  Stream<AppLockState> get lockStates => _states.stream;

  @override
  Future<AuthenticationResult> authenticateBiometrically() async =>
      const AuthenticationResult(authenticated: false);

  @override
  Future<void> changePin({
    required String currentPin,
    required String newPin,
  }) async {}

  @override
  Future<void> completeRecoverySetup({required String pin}) async {}

  @override
  Future<String> decryptText(EncryptedValue encrypted) =>
      throw UnimplementedError();

  @override
  Future<Uint8List> decryptBytes(Uint8List ciphertext) =>
      throw UnimplementedError();

  @override
  Future<EncryptedValue> encryptText(String plaintext) =>
      throw UnimplementedError();

  @override
  Future<Uint8List> encryptBytes(Uint8List plaintext) =>
      throw UnimplementedError();

  @override
  Future<void> initialize({required String pin}) async {}

  @override
  Future<bool> get isInitialized async => true;

  @override
  Future<bool> get isRecoverySetupPending async => false;

  @override
  Future<void> lock() async {
    lockCount++;
    _states.add(AppLockState.locked);
  }

  @override
  Future<AuthenticationResult> reauthenticate() async =>
      const AuthenticationResult(authenticated: false);

  @override
  Future<void> restoreWrappedDataKey({
    required Uint8List wrappedKey,
    required String recoveryPassword,
  }) async {}

  @override
  Future<AuthenticationResult> unlockWithPin(String pin) async =>
      const AuthenticationResult(authenticated: false);

  @override
  Future<bool> verifyPin(String pin) async => false;

  @override
  Future<Uint8List> wrapDataKeyForRecovery(String recoveryPassword) =>
      throw UnimplementedError();
}
