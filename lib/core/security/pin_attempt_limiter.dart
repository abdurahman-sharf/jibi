import 'dart:convert';
import 'dart:typed_data';

import 'secure_key_store.dart';

/// Slows down PIN guessing on the device.
///
/// The first [freeAttempts] wrong PINs in a row cost nothing (typos). From the
/// next one the PIN is refused for [lockouts] in turn (30 s, 1, 5, 15, then 60
/// minutes), and a correct PIN starts the count again. The state lives in the
/// [SecureKeyStore], so closing the app does not reset it. If the clock is set
/// back before the last failure, the whole lockout is treated as still
/// running, so rewinding the clock never shortens a wait.
final class PinAttemptLimiter {
  PinAttemptLimiter({
    required SecureKeyStore keyStore,
    DateTime Function()? clock,
  }) : _keyStore = keyStore,
       _clock = clock ?? DateTime.now;

  static const String storeKey = 'jibi.security.pin-attempts.v1';
  static const int freeAttempts = 4;
  static const List<Duration> lockouts = <Duration>[
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 5),
    Duration(minutes: 15),
    Duration(minutes: 60),
  ];

  final SecureKeyStore _keyStore;
  final DateTime Function() _clock;

  /// How long a PIN must still not be tried, or null when it may be tried now.
  Future<Duration?> remaining() async {
    final state = await _read();
    if (state.lockMs <= 0) return null;
    final elapsedMs = _clock().millisecondsSinceEpoch - state.lastFailureMs;
    final leftMs = elapsedMs < 0 ? state.lockMs : state.lockMs - elapsedMs;
    return leftMs > 0 ? Duration(milliseconds: leftMs) : null;
  }

  /// Counts a wrong PIN. Returns the lockout that starts now, or null while
  /// free attempts remain.
  Future<Duration?> recordFailure() async {
    final state = await _read();
    final failures = state.failures + 1;
    var lockMs = 0;
    if (failures > freeAttempts) {
      final step = failures - freeAttempts - 1;
      lockMs = lockouts[step < lockouts.length ? step : lockouts.length - 1]
          .inMilliseconds;
    }
    await _write(
      _State(
        failures: failures,
        lastFailureMs: _clock().millisecondsSinceEpoch,
        lockMs: lockMs,
      ),
    );
    return lockMs > 0 ? Duration(milliseconds: lockMs) : null;
  }

  /// Forgets all failures (after a correct PIN or when the PIN is replaced).
  Future<void> reset() async {
    if (await _keyStore.read(storeKey) != null) {
      await _keyStore.delete(storeKey);
    }
  }

  Future<_State> _read() async {
    final bytes = await _keyStore.read(storeKey);
    if (bytes == null) return const _State.empty();
    try {
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map<String, Object?>) return const _State.empty();
      final failures = json['failures'];
      final lastFailureMs = json['lastFailureMs'];
      final lockMs = json['lockMs'];
      if (failures is! int || lastFailureMs is! int || lockMs is! int) {
        return const _State.empty();
      }
      return _State(
        failures: failures < 0 ? 0 : failures,
        lastFailureMs: lastFailureMs,
        lockMs: lockMs < 0 ? 0 : lockMs,
      );
    } on FormatException {
      // A damaged record must never lock the owner out of their own data.
      return const _State.empty();
    }
  }

  Future<void> _write(_State state) => _keyStore.write(
    storeKey,
    Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, Object>{
          'failures': state.failures,
          'lastFailureMs': state.lastFailureMs,
          'lockMs': state.lockMs,
        }),
      ),
    ),
  );
}

final class _State {
  const _State({
    required this.failures,
    required this.lastFailureMs,
    required this.lockMs,
  });

  const _State.empty() : failures = 0, lastFailureMs = 0, lockMs = 0;

  final int failures;
  final int lastFailureMs;
  final int lockMs;
}

/// The Arabic wait time shown to the user, rounded up: «30 ثانية»,
/// «دقيقتين», «15 دقيقة», «ساعة».
String describeWait(Duration wait) {
  final seconds = (wait.inMilliseconds / 1000).ceil().clamp(1, 24 * 3600);
  if (seconds < 60) return '$seconds ثانية';
  final minutes = (seconds / 60).ceil();
  if (minutes >= 60) return 'ساعة';
  if (minutes == 1) return 'دقيقة';
  if (minutes == 2) return 'دقيقتين';
  if (minutes <= 10) return '$minutes دقائق';
  return '$minutes دقيقة';
}

/// What the user is told while PIN attempts are paused.
String pinLockoutMessage(Duration retryAfter) =>
    'محاولات كثيرة خاطئة. أعد المحاولة بعد ${describeWait(retryAfter)}.';
