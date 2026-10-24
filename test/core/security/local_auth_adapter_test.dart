import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';

import 'package:jibi/core/security/platform_adapters.dart';

class _FakeLocalAuth extends LocalAuthentication {
  _FakeLocalAuth({
    this.enrolled = const [BiometricType.fingerprint],
    this.authenticateError,
    this.enrolledError,
    this.deviceSupported = true,
    this.deviceSupportedError,
  });

  final List<BiometricType> enrolled;
  final Object? authenticateError;
  final Object? enrolledError;
  final bool deviceSupported;
  final Object? deviceSupportedError;
  int authenticateCalls = 0;
  bool? lastBiometricOnly;

  @override
  Future<List<BiometricType>> getAvailableBiometrics() async {
    if (enrolledError != null) throw enrolledError!;
    return enrolled;
  }

  @override
  Future<bool> isDeviceSupported() async {
    if (deviceSupportedError != null) throw deviceSupportedError!;
    return deviceSupported;
  }

  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<Object?> authMessages = const <Object?>[],
    bool biometricOnly = false,
    bool sensitiveTransaction = true,
    bool persistAcrossBackgrounding = false,
  }) async {
    authenticateCalls += 1;
    lastBiometricOnly = biometricOnly;
    if (authenticateError != null) throw authenticateError!;
    return true;
  }
}

void main() {
  test('reports capability only when a biometric is actually enrolled', () async {
    expect(
      await LocalAuthBiometricAuthenticator(
        localAuthentication: _FakeLocalAuth(),
      ).canAuthenticate(),
      isTrue,
    );
    expect(
      await LocalAuthBiometricAuthenticator(
        localAuthentication: _FakeLocalAuth(enrolled: const []),
      ).canAuthenticate(),
      isFalse,
    );
  });

  test('does not prompt when nothing is enrolled', () async {
    final local = _FakeLocalAuth(enrolled: const []);
    final adapter = LocalAuthBiometricAuthenticator(localAuthentication: local);

    expect(await adapter.authenticate(reason: 'test'), isFalse);
    expect(local.authenticateCalls, 0);
  });

  test('maps LocalAuthException and platform failures to false', () async {
    for (final error in <Object>[
      const LocalAuthException(code: LocalAuthExceptionCode.userCanceled),
      const LocalAuthException(code: LocalAuthExceptionCode.biometricLockout),
      StateError('channel failure'),
    ]) {
      final adapter = LocalAuthBiometricAuthenticator(
        localAuthentication: _FakeLocalAuth(authenticateError: error),
      );
      expect(await adapter.authenticate(reason: 'test'), isFalse);
    }
    final failing = LocalAuthBiometricAuthenticator(
      localAuthentication: _FakeLocalAuth(
        enrolledError: const LocalAuthException(
          code: LocalAuthExceptionCode.noBiometricHardware,
        ),
      ),
    );
    expect(await failing.canAuthenticate(), isFalse);
  });

  test('passes through a successful biometric prompt', () async {
    final adapter = LocalAuthBiometricAuthenticator(
      localAuthentication: _FakeLocalAuth(),
    );

    expect(await adapter.authenticate(reason: 'test'), isTrue);
  });

  group('device identity check for a forgotten PIN', () {
    test('asks the system prompt with the screen lock allowed', () async {
      final local = _FakeLocalAuth();
      final adapter = LocalAuthBiometricAuthenticator(localAuthentication: local);

      expect(await adapter.verifyIdentity(reason: 'test'), isTrue);
      expect(local.authenticateCalls, 1);
      expect(local.lastBiometricOnly, isFalse);
    });

    test('the ordinary biometric check stays biometric-only', () async {
      final local = _FakeLocalAuth();
      final adapter = LocalAuthBiometricAuthenticator(localAuthentication: local);

      await adapter.authenticate(reason: 'test');
      expect(local.lastBiometricOnly, isTrue);
    });

    test('works with a screen lock alone, no fingerprint enrolled', () async {
      final local = _FakeLocalAuth(enrolled: const []);
      final adapter = LocalAuthBiometricAuthenticator(localAuthentication: local);

      expect(await adapter.canVerifyIdentity(), isTrue);
      expect(await adapter.verifyIdentity(reason: 'test'), isTrue);
      // The biometric-only path is still closed on the same phone.
      expect(await adapter.canAuthenticate(), isFalse);
    });

    test('a phone with neither reports it and shows no prompt', () async {
      final local = _FakeLocalAuth(enrolled: const [], deviceSupported: false);
      final adapter = LocalAuthBiometricAuthenticator(localAuthentication: local);

      expect(await adapter.canVerifyIdentity(), isFalse);
      expect(await adapter.verifyIdentity(reason: 'test'), isFalse);
      expect(local.authenticateCalls, 0);
    });

    test('cancellation and platform failures mean not confirmed', () async {
      for (final error in <Object>[
        const LocalAuthException(code: LocalAuthExceptionCode.userCanceled),
        const LocalAuthException(code: LocalAuthExceptionCode.biometricLockout),
        StateError('channel failure'),
      ]) {
        final adapter = LocalAuthBiometricAuthenticator(
          localAuthentication: _FakeLocalAuth(authenticateError: error),
        );
        expect(await adapter.verifyIdentity(reason: 'test'), isFalse);
      }
      final failing = LocalAuthBiometricAuthenticator(
        localAuthentication: _FakeLocalAuth(deviceSupportedError: StateError('x')),
      );
      expect(await failing.canVerifyIdentity(), isFalse);
    });
  });
}
