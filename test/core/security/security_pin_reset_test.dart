import 'package:flutter_test/flutter_test.dart';
import 'package:jibi/core/errors/app_exception.dart';
import 'package:jibi/core/security/security.dart';

import '../../support/device_identity.dart';
import '../../support/memory_keys.dart';

/// Replacing a forgotten PIN after the phone confirmed the person. The PIN only
/// guards the lock screen (the data key is random and stored apart), so the
/// reset must never change what can be decrypted.
void main() {
  late FakeDeviceIdentity device;
  late DateTime now;

  Future<AesGcmSecurityService> service({
    BiometricAuthenticator? authenticator,
  }) async {
    final service = AesGcmSecurityService(
      keyStore: MemoryKeys(),
      biometricAuthenticator: authenticator ?? device,
      clock: () => now,
    );
    await service.initialize(pin: '123456');
    return service;
  }

  Matcher throwsSecurity(String code) => throwsA(
    isA<SecurityException>().having((error) => error.code, 'code', code),
  );

  setUp(() {
    device = FakeDeviceIdentity();
    now = DateTime.utc(2026, 9, 21, 12);
  });

  test('a reset without a confirmed device check is refused', () async {
    final security = await service();
    await security.lock();

    await expectLater(
      security.resetPin(newPin: '654321'),
      throwsSecurity('pin_reset_not_authorized'),
    );

    expect((await security.unlockWithPin('654321')).authenticated, isFalse);
    expect((await security.unlockWithPin('123456')).authenticated, isTrue);
  });

  test('after the check the new PIN opens the app and the old one does not, '
      'with the same data', () async {
    final security = await service();
    final secret = await security.encryptText('protected');
    await security.lock();

    expect(await security.canVerifyDeviceIdentity(), isTrue);
    final verified = await security.verifyDeviceIdentity();
    expect(verified.authenticated, isTrue);
    expect(device.prompts, 1);
    // Confirming who you are does not unlock anything by itself.
    await expectLater(
      security.decryptText(secret),
      throwsSecurity('app_locked'),
    );

    final states = <AppLockState>[];
    final subscription = security.lockStates.listen(states.add);
    await security.resetPin(newPin: '654321');
    await Future<void>.delayed(Duration.zero);
    await subscription.cancel();
    expect(states, [AppLockState.unlocked]);
    // The very same ciphertext opens: the data key did not change.
    expect(await security.decryptText(secret), 'protected');

    await security.lock();
    expect((await security.unlockWithPin('123456')).authenticated, isFalse);
    expect((await security.unlockWithPin('654321')).authenticated, isTrue);
    expect(await security.decryptText(secret), 'protected');
  });

  test('one confirmation allows one reset', () async {
    final security = await service();
    await security.lock();
    await security.verifyDeviceIdentity();
    await security.resetPin(newPin: '654321');
    await security.lock();

    await expectLater(
      security.resetPin(newPin: '111111'),
      throwsSecurity('pin_reset_not_authorized'),
    );
    expect((await security.unlockWithPin('654321')).authenticated, isTrue);
  });

  test('the confirmation lasts five minutes', () async {
    final security = await service();
    await security.lock();

    await security.verifyDeviceIdentity();
    now = now.add(AesGcmSecurityService.pinResetWindow);
    await expectLater(
      security.resetPin(newPin: '654321'),
      throwsSecurity('pin_reset_not_authorized'),
    );

    await security.verifyDeviceIdentity();
    now = now.add(AesGcmSecurityService.pinResetWindow - const Duration(seconds: 1));
    await security.resetPin(newPin: '654321');
    await security.lock();
    expect((await security.unlockWithPin('654321')).authenticated, isTrue);
  });

  test('locking the app cancels a pending confirmation', () async {
    final security = await service();
    await security.lock();
    await security.verifyDeviceIdentity();
    await security.lock();

    await expectLater(
      security.resetPin(newPin: '654321'),
      throwsSecurity('pin_reset_not_authorized'),
    );
  });

  test('a weak new PIN is rejected and the old PIN keeps working', () async {
    final security = await service();
    await security.lock();
    await security.verifyDeviceIdentity();

    await expectLater(
      security.resetPin(newPin: '123'),
      throwsA(isA<ValidationException>()),
    );

    expect((await security.unlockWithPin('123456')).authenticated, isTrue);
  });

  test('a phone without a fingerprint or screen lock says so and shows no '
      'prompt', () async {
    device.available = false;
    final security = await service();
    await security.lock();

    expect(await security.canVerifyDeviceIdentity(), isFalse);
    final result = await security.verifyDeviceIdentity();
    expect(result.authenticated, isFalse);
    expect(result.reason, 'device_auth_unavailable');
    expect(device.prompts, 0);
    await expectLater(
      security.resetPin(newPin: '654321'),
      throwsSecurity('pin_reset_not_authorized'),
    );
  });

  test('a cancelled or failed system prompt changes nothing', () async {
    device.confirms = false;
    final security = await service();
    await security.lock();

    final result = await security.verifyDeviceIdentity();
    expect(result.authenticated, isFalse);
    expect(result.reason, 'identity_not_confirmed');
    await expectLater(
      security.resetPin(newPin: '654321'),
      throwsSecurity('pin_reset_not_authorized'),
    );
    expect((await security.unlockWithPin('123456')).authenticated, isTrue);
  });

  test('a failed check after a good one withdraws the earlier permission', () async {
    final security = await service();
    await security.lock();
    await security.verifyDeviceIdentity();
    device.confirms = false;
    await security.verifyDeviceIdentity();

    await expectLater(
      security.resetPin(newPin: '654321'),
      throwsSecurity('pin_reset_not_authorized'),
    );
  });

  test('an authenticator that cannot verify the device is reported as unavailable', () async {
    // NoBiometrics is the plain biometric fake: no DeviceIdentityVerifier.
    final security = await service(authenticator: NoBiometrics());
    await security.lock();

    expect(await security.canVerifyDeviceIdentity(), isFalse);
    expect(
      (await security.verifyDeviceIdentity()).reason,
      'device_auth_unavailable',
    );
  });

  test('nothing to reset before the app has a PIN', () async {
    final security = AesGcmSecurityService(
      keyStore: MemoryKeys(),
      biometricAuthenticator: device,
      clock: () => now,
    );

    final result = await security.verifyDeviceIdentity();
    expect(result.authenticated, isFalse);
    expect(result.reason, 'not_initialized');
    expect(device.prompts, 0);
  });

  test('a reset also ends the pause after too many wrong PINs', () async {
    final security = await service();
    await security.lock();
    AuthenticationResult? last;
    for (var attempt = 0; attempt < 5; attempt++) {
      last = await security.unlockWithPin('000000');
    }
    expect(last!.reason, 'pin_locked_out');
    expect((await security.unlockWithPin('123456')).reason, 'pin_locked_out');

    await security.verifyDeviceIdentity();
    await security.resetPin(newPin: '654321');
    await security.lock();

    expect((await security.unlockWithPin('654321')).authenticated, isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
