@Tags(['perf'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jibi/core/security/kdf.dart';
import 'package:jibi/core/security/pin_verifier.dart';
import 'package:jibi/core/security/security_primitives.dart';

/// Measures the actual, real cost of PBKDF2-HMAC-SHA256 at the app's
/// production iteration count, using the production [Kdf] code path exactly
/// as `main.dart` configures it. Written to answer, with numbers instead of
/// assumptions, the question "is PBKDF2 the 7-second startup bottleneck?"
///
/// This runs on the host machine (desktop CPU), not a phone: real mobile
/// hardware — especially a mid/low-range Android CPU with no hardware crypto
/// acceleration reachable from pure-Dart code — is typically several times
/// slower at scalar hashing than a modern desktop. Treat these numbers as a
/// LOWER BOUND on the phone's real cost, not the final answer; the
/// PIN → Home report asks for a real-device Release measurement too.
void main() {
  const iterations = 600000; // PinVerifier._iterations, kept in sync manually.
  final salt = secureRandomBytes(16);

  test('PBKDF2-HMAC-SHA256 at 600k iterations: main isolate vs Isolate.run',
      () async {
    Kdf.useBackgroundIsolate = false;
    final mainIsolate = Stopwatch()..start();
    await Kdf.pbkdf2Sha256(
      password: '123456',
      salt: salt,
      iterations: iterations,
    );
    mainIsolate.stop();

    Kdf.useBackgroundIsolate = true;
    final backgroundIsolate = Stopwatch()..start();
    await Kdf.pbkdf2Sha256(
      password: '123456',
      salt: salt,
      iterations: iterations,
    );
    backgroundIsolate.stop();

    // ignore: avoid_print
    print(
      'PBKDF2 600k iterations — main isolate: ${mainIsolate.elapsedMilliseconds} ms, '
      'Isolate.run: ${backgroundIsolate.elapsedMilliseconds} ms '
      '(difference is roughly the isolate spawn overhead, desktop CPU)',
    );
    // A sanity floor, not a performance assertion: PBKDF2 at 600k iterations
    // is expected to take real, measurable time even on a desktop CPU — if
    // this ever reports near-zero, something is silently wrong (e.g. the
    // iteration count was bypassed), not "fast".
    expect(mainIsolate.elapsedMilliseconds, greaterThan(50));
  });

  test('the full PinVerifier.create + verify round trip, end to end', () async {
    Kdf.useBackgroundIsolate = true;
    final create = Stopwatch()..start();
    final verifier = await PinVerifier.create('123456');
    create.stop();

    final verify = Stopwatch()..start();
    final ok = await verifier.verify('123456');
    verify.stop();

    // ignore: avoid_print
    print(
      'PinVerifier.create: ${create.elapsedMilliseconds} ms, '
      'PinVerifier.verify: ${verify.elapsedMilliseconds} ms (background isolate, desktop CPU)',
    );
    expect(ok, isTrue);
  });
}
