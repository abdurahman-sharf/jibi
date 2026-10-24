import 'package:flutter/foundation.dart';

/// Temporary, lightweight timing diagnostics for the PIN → Home startup
/// performance investigation.
///
/// Safe to leave in a release build: it only ever measures and prints via
/// [debugPrint] (visible in `flutter run --release`'s console or `adb
/// logcat`), and never gates, delays, retries or changes anything it
/// measures. It is deliberately not behind `kDebugMode` — the whole point is
/// to get real numbers from a Release build on a real phone.
///
/// This is diagnostic scaffolding, not a permanent feature: once the numbers
/// are confirmed good on real devices, it is fine to delete this file and its
/// call sites (`JibiApplication.create`, `AesGcmSecurityService.unlockWithPin`,
/// `jibi_app.dart`'s lock screen).
final class PhaseTrace {
  PhaseTrace(this.label);

  final String label;
  final List<MapEntry<String, int>> _phases = <MapEntry<String, int>>[];
  final Stopwatch _total = Stopwatch()..start();

  /// Times [action] under [phase] and returns its result (or rethrows its
  /// error) unchanged — this never changes what the caller awaits, only
  /// records how long it took.
  Future<T> measure<T>(String phase, Future<T> Function() action) async {
    final watch = Stopwatch()..start();
    try {
      return await action();
    } finally {
      _phases.add(MapEntry(phase, watch.elapsedMilliseconds));
    }
  }

  /// Records a duration measured elsewhere (e.g. a phase timed by the
  /// caller before this trace existed).
  void mark(String phase, int milliseconds) =>
      _phases.add(MapEntry(phase, milliseconds));

  /// Prints every recorded phase and the running total elapsed since this
  /// trace was created.
  void report() {
    final buffer = StringBuffer('[jibi-timing] $label\n');
    for (final phase in _phases) {
      buffer.writeln('  ${phase.key}: ${phase.value} ms');
    }
    buffer.write('  Total so far: ${_total.elapsedMilliseconds} ms');
    debugPrint(buffer.toString());
  }
}

/// Marks the moment the user pressed the unlock button (PIN or biometric), so
/// the app shell can print the true button-press → Home-frame wall-clock gap
/// once the lock screen comes down — this covers a little more than
/// [PhaseTrace] on `unlockWithPin` alone: the frame Flutter needs to flip
/// Home's `Offstage` off and paint it.
final class UnlockTiming {
  UnlockTiming._();

  static DateTime? _pressedAt;

  /// Call when a verification attempt actually starts (not on a press that
  /// was ignored because one was already in flight).
  static void markPressed() => _pressedAt = DateTime.now();

  /// Prints the elapsed time since the last [markPressed] and clears the
  /// mark, so a later, unrelated lock/unlock never reports a stale number.
  static void reportHomeVisible() {
    final pressedAt = _pressedAt;
    if (pressedAt == null) return;
    _pressedAt = null;
    debugPrint(
      '[jibi-timing] Button press → Home frame: '
      '${DateTime.now().difference(pressedAt).inMilliseconds} ms',
    );
  }
}
