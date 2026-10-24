import 'dart:async';

abstract interface class ClipboardPort {
  Future<void> writeText(String value);
  Future<String?> readText();
}

abstract interface class ScheduledTask {
  void cancel();
}

abstract interface class ClipboardScheduler {
  ScheduledTask schedule(Duration delay, Future<void> Function() action);
}

final class TimerClipboardScheduler implements ClipboardScheduler {
  const TimerClipboardScheduler();

  @override
  ScheduledTask schedule(Duration delay, Future<void> Function() action) =>
      _TimerScheduledTask(Timer(delay, () => unawaited(action())));
}

final class _TimerScheduledTask implements ScheduledTask {
  _TimerScheduledTask(this._timer);

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}

/// Clears a copied secret from the clipboard after a delay, without erasing
/// something newer the user copied in the meantime.
///
/// The clipboard is cleared when it still holds the secret, **or when it
/// cannot be read**: since Android 10 an app in the background gets nothing
/// back from a read, and the background is exactly where the user is while
/// pasting the secret into another app. Skipping the clear then would leave the
/// password on the clipboard while the screen promises to remove it.
final class SensitiveClipboardController {
  SensitiveClipboardController({
    required this.clipboard,
    this.scheduler = const TimerClipboardScheduler(),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final ClipboardPort clipboard;
  final ClipboardScheduler scheduler;
  final DateTime Function() _clock;
  ScheduledTask? _clearTask;
  String? _pendingSecret;
  DateTime? _dueAt;

  Future<void> copySecret(String secret, {required Duration clearAfter}) async {
    _clearTask?.cancel();
    await clipboard.writeText(secret);
    _pendingSecret = secret;
    _dueAt = _clock().add(clearAfter);
    _clearTask = scheduler.schedule(clearAfter, clearNow);
  }

  /// Clears the clipboard now if it still holds the last copied secret (or
  /// cannot be read). Does nothing when no secret is waiting.
  Future<void> clearNow() async {
    final secret = _pendingSecret;
    if (secret == null) return;
    _pendingSecret = null;
    _dueAt = null;
    _clearTask?.cancel();
    _clearTask = null;
    String? current;
    try {
      current = await clipboard.readText();
    } on Object {
      current = null;
    }
    if (current != null && current != secret) return;
    try {
      await clipboard.writeText('');
    } on Object {
      // Best effort: there is nothing else to try.
    }
  }

  /// For when the app comes back to the foreground: the timer may have been
  /// frozen with the process while it was in the background, so a secret whose
  /// time has passed is cleared now.
  Future<void> clearIfDue() async {
    final due = _dueAt;
    if (_pendingSecret == null || due == null) return;
    if (!_clock().isBefore(due)) await clearNow();
  }

  void dispose() => _clearTask?.cancel();
}
