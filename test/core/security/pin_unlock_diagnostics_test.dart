import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/core/security/kdf.dart';
import 'package:jibi/core/security/security.dart';

import '../../support/memory_keys.dart';

/// Regression coverage for the PIN → Home performance investigation:
/// - a real PIN check never runs PBKDF2 more than once per attempt;
/// - a paused (locked-out) attempt runs it zero times ("guessing gets no
///   answer at all");
/// - the batched secure-storage read added to `unlockWithPin` (verifier, data
///   key and the recovery-pending flag fetched together instead of the
///   verifier being read twice and the data key twice) still enforces the
///   exact same rules as before: no verifier, no data key, or a pending
///   recovery setup all still refuse the login the same way.
void main() {
  late MemoryKeys keys;
  late AesGcmSecurityService security;

  setUp(() async {
    Kdf.useBackgroundIsolate = false; // the in-process path, like every test.
    keys = MemoryKeys();
    security = AesGcmSecurityService(
      keyStore: keys,
      biometricAuthenticator: NoBiometrics(),
    );
    await security.initialize(pin: '123456');
    Kdf.callCount = 0; // only count calls made by the test itself below.
  });

  test('a correct PIN runs PBKDF2 exactly once', () async {
    final result = await security.unlockWithPin('123456');
    expect(result.authenticated, isTrue);
    expect(Kdf.callCount, 1);
  });

  test('a wrong PIN also runs PBKDF2 exactly once (it must be computed to '
      'know it is wrong) — never twice', () async {
    final result = await security.unlockWithPin('000000');
    expect(result.authenticated, isFalse);
    expect(result.reason, 'invalid_pin');
    expect(Kdf.callCount, 1);
  });

  test('a paused (locked-out) attempt runs PBKDF2 zero times', () async {
    for (var i = 0; i < 5; i++) {
      await security.unlockWithPin('000000');
    }
    Kdf.callCount = 0;
    final result = await security.unlockWithPin('123456');
    expect(result.reason, 'pin_locked_out');
    expect(Kdf.callCount, 0);
  });

  test('several unlock attempts in a row each run PBKDF2 exactly once, never '
      'accumulating extra calls', () async {
    await security.unlockWithPin('123456');
    await security.lock();
    await security.unlockWithPin('123456');
    await security.lock();
    await security.unlockWithPin('123456');
    expect(Kdf.callCount, 3);
  });

  test('a missing data key refuses the login without touching PBKDF2',
      () async {
    keys.values.remove('jibi.security.data-key.v1');
    final result = await security.unlockWithPin('123456');
    expect(result.authenticated, isFalse);
    expect(result.reason, 'not_initialized');
    expect(Kdf.callCount, 0);
  });

  test('a pending recovery setup refuses a normal PIN login, without '
      'touching PBKDF2', () async {
    // Simulates the state `completeRecoverySetup` has not yet cleared —
    // written directly rather than through the real (also PBKDF2-heavy)
    // recovery wrap/restore flow, which is exercised elsewhere.
    keys.values['jibi.security.recovery-pending.v1'] = Uint8List.fromList([1]);
    final result = await security.unlockWithPin('123456');
    expect(result.authenticated, isFalse);
    expect(result.reason, 'not_initialized');
    expect(Kdf.callCount, 0);
  });
}
