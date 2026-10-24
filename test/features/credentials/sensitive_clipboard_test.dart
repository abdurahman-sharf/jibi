import 'package:flutter_test/flutter_test.dart';
import 'package:jibi/features/credentials/domain/clipboard.dart';

void main() {
  late _FakeClipboard clipboard;
  late _ManualScheduler scheduler;
  late DateTime now;
  late SensitiveClipboardController controller;

  setUp(() {
    clipboard = _FakeClipboard();
    scheduler = _ManualScheduler();
    now = DateTime.utc(2026, 9, 21, 12);
    controller = SensitiveClipboardController(
      clipboard: clipboard,
      scheduler: scheduler,
      clock: () => now,
    );
  });

  test('clears the secret when the timer fires and it is still there', () async {
    await controller.copySecret('s3cret', clearAfter: const Duration(seconds: 30));
    expect(clipboard.text, 's3cret');

    await scheduler.fire();

    expect(clipboard.text, '');
  });

  test('leaves newer clipboard content alone', () async {
    await controller.copySecret('s3cret', clearAfter: const Duration(seconds: 30));
    clipboard.text = 'something else the user copied';

    await scheduler.fire();

    expect(clipboard.text, 'something else the user copied');
  });

  test('clears even when the clipboard cannot be read', () async {
    // Android 10+ answers a background app's read with nothing at all, and the
    // background is where the user is while pasting the secret elsewhere.
    await controller.copySecret('s3cret', clearAfter: const Duration(seconds: 30));
    clipboard.readable = false;

    await scheduler.fire();

    expect(clipboard.text, '');
  });

  test('clears when reading the clipboard throws', () async {
    await controller.copySecret('s3cret', clearAfter: const Duration(seconds: 30));
    clipboard.readThrows = true;

    await scheduler.fire();

    expect(clipboard.text, '');
  });

  test('a second copy replaces the first timer', () async {
    await controller.copySecret('first', clearAfter: const Duration(seconds: 30));
    await controller.copySecret('second', clearAfter: const Duration(seconds: 30));

    expect(scheduler.cancelled, 1);
    await scheduler.fire();
    expect(clipboard.text, '');
    expect(clipboard.writes, ['first', 'second', '']);
  });

  group('clearIfDue (app back in the foreground)', () {
    test('does nothing before the time is up', () async {
      await controller.copySecret('s3cret', clearAfter: const Duration(seconds: 30));
      now = now.add(const Duration(seconds: 29));

      await controller.clearIfDue();

      expect(clipboard.text, 's3cret');
    });

    test('clears once the time is up, even if the timer never ran', () async {
      await controller.copySecret('s3cret', clearAfter: const Duration(seconds: 30));
      now = now.add(const Duration(seconds: 30));

      await controller.clearIfDue();

      expect(clipboard.text, '');
      // Nothing is pending any more: a later call must not touch the clipboard.
      clipboard.text = 'new';
      await controller.clearIfDue();
      await scheduler.fire();
      expect(clipboard.text, 'new');
    });

    test('does nothing when nothing was copied', () async {
      clipboard.text = 'user text';
      await controller.clearIfDue();
      expect(clipboard.text, 'user text');
    });
  });
}

final class _FakeClipboard implements ClipboardPort {
  String? text;
  bool readable = true;
  bool readThrows = false;
  final List<String> writes = <String>[];

  @override
  Future<String?> readText() async {
    if (readThrows) throw StateError('clipboard unavailable');
    return readable ? text : null;
  }

  @override
  Future<void> writeText(String value) async {
    writes.add(value);
    text = value;
  }
}

final class _ManualScheduler implements ClipboardScheduler {
  Future<void> Function()? _action;
  int cancelled = 0;

  @override
  ScheduledTask schedule(Duration delay, Future<void> Function() action) {
    _action = action;
    return _Task(() {
      cancelled++;
      _action = null;
    });
  }

  Future<void> fire() async => await _action?.call();
}

final class _Task implements ScheduledTask {
  _Task(this._onCancel);

  final void Function() _onCancel;

  @override
  void cancel() => _onCancel();
}
