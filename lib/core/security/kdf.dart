import 'dart:async' show TimeoutException;
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart' show DartPbkdf2;
import 'package:cryptography_flutter/cryptography_flutter.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

/// PBKDF2-HMAC-SHA256 key derivation shared by the PIN verifier, the recovery
/// key wrapping and the backup container.
///
/// Two ways this can run fast enough to never worry the UI:
///
/// - **Native (Android only).** `cryptography_flutter`'s native PBKDF2 does
///   the actual 600k rounds on the platform side, off Dart entirely; the
///   `await` on its method-channel call does not block the Dart event loop
///   (unlike CPU-bound pure-Dart work), so it runs directly on the calling
///   isolate — typically well under a second. [_derive] arms it every call
///   (`FlutterCryptography.registerWith`, not the `Cryptography.
///   freezeInstance`-based `enable()` shortcut, is what actually flips the
///   plugin's internal "is this real" flag its channel calls check) and, on
///   ANY failure — including one that never resolves at all, guarded by
///   [_nativeTimeout] — falls back to the pure Dart path below, so a PIN
///   check can never fail, or hang, because the speed-up did.
/// - **Pure Dart, off the UI isolate.** 600k iterations take real seconds in
///   pure Dart, which would freeze the UI if run on it. When
///   [useBackgroundIsolate] is on (the app turns it on at startup) this runs
///   in a short-lived isolate instead. Deliberately never attempts a
///   platform-channel call from that isolate (background isolates need extra,
///   fragile setup — `BackgroundIsolateBinaryMessenger.ensureInitialized`,
///   observed to corrupt the VM in a plain, non-widget `test()` — for close
///   to no benefit, since the native path above already runs on the calling
///   isolate). Tests keep the in-process path so fake-async widget tests
///   never wait on a real isolate.
abstract final class Kdf {
  static bool useBackgroundIsolate = false;

  /// Counts every call to [pbkdf2Sha256], for tests that assert a PIN check
  /// never runs the 600k-iteration derivation more than once per attempt.
  /// Never read or reset in production code.
  static int callCount = 0;

  static Future<Uint8List> pbkdf2Sha256({
    required String password,
    required List<int> salt,
    required int iterations,
    int bits = 256,
  }) {
    callCount++;
    final saltBytes = Uint8List.fromList(salt);
    if (_nativeCryptoMayBeFast) {
      // Runs on the calling isolate on purpose — see the class doc.
      return _derive(password, saltBytes, iterations, bits);
    }
    if (!useBackgroundIsolate) {
      return _deriveDartOnly(password, saltBytes, iterations, bits);
    }
    return Isolate.run(
      () => _deriveDartOnly(password, saltBytes, iterations, bits),
    );
  }

  /// Whether attempting the native path is worthwhile at all. Android only
  /// (per `cryptography_flutter`'s own PBKDF2 support); [_derive] still
  /// falls back safely if the actual attempt fails despite this being true.
  ///
  /// Deliberately `Platform.isAndroid` (the real OS), not
  /// `defaultTargetPlatform` — `cryptography_flutter`'s own internal check
  /// uses the latter, which `testWidgets()` defaults to `android` regardless
  /// of the host OS (observed: it made a plain `test()` benchmark correctly
  /// skip the native path on this Windows machine, but a `testWidgets()`
  /// onboarding flow attempt it and hang forever awaiting a platform channel
  /// that was never really there).
  static bool get _nativeCryptoMayBeFast => !kIsWeb && Platform.isAndroid;

  /// However slow 600k real pure-Dart iterations are (measured: several
  /// seconds even on a desktop CPU), that is the ceiling worth waiting on the
  /// native attempt before giving up on it — a channel call that takes
  /// longer than this was never going to beat the fallback anyway.
  static const _nativeTimeout = Duration(seconds: 3);

  /// Tries the native path (arming it first); on ANY failure — an exception,
  /// or a channel call that simply never answers — falls back to the
  /// explicit, always-available [DartPbkdf2]. Never [Isolate.run], since this
  /// only runs when [_nativeCryptoMayBeFast], where a pure-Dart fallback is
  /// the rare exception, not the common case the isolate hop exists for.
  static Future<Uint8List> _derive(
    String password,
    Uint8List salt,
    int iterations,
    int bits,
  ) async {
    try {
      FlutterCryptography.registerWith();
      final key = await Pbkdf2.hmacSha256(iterations: iterations, bits: bits)
          .deriveKeyFromPassword(password: password, nonce: salt)
          .timeout(
            _nativeTimeout,
            onTimeout: () =>
                throw TimeoutException('cryptography_flutter PBKDF2 call'),
          );
      return Uint8List.fromList(await key.extractBytes());
    } on Object {
      return _deriveDartOnly(password, salt, iterations, bits);
    }
  }

  /// The plain, standard PBKDF2-HMAC-SHA256 implementation, independent of
  /// `Cryptography.instance` (so it is unaffected by whatever another
  /// isolate, or [_derive] above, has done to it).
  static Future<Uint8List> _deriveDartOnly(
    String password,
    Uint8List salt,
    int iterations,
    int bits,
  ) async {
    final key = await DartPbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: bits,
    ).deriveKeyFromPassword(password: password, nonce: salt);
    return Uint8List.fromList(await key.extractBytes());
  }
}
