import 'dart:async';

/// Re-runs [query] now and after every event on [changes].
///
/// The subscription to [changes] is made before the first query runs, so a
/// write that lands while the first query is in flight is never missed.
/// Overlapping refreshes are coalesced into one follow-up query.
Stream<T> watchBookQuery<T>(
  Stream<void> changes,
  Future<T> Function() query,
) {
  late final StreamController<T> controller;
  StreamSubscription<void>? subscription;
  var loading = false;
  var pending = false;

  Future<void> load() async {
    if (loading) {
      pending = true;
      return;
    }
    loading = true;
    try {
      do {
        pending = false;
        final value = await query();
        if (!controller.isClosed) {
          controller.add(value);
        }
      } while (pending && !controller.isClosed);
    } on Object catch (error, stackTrace) {
      if (!controller.isClosed) {
        controller.addError(error, stackTrace);
      }
    } finally {
      loading = false;
    }
  }

  controller = StreamController<T>(
    onListen: () {
      subscription = changes.listen((_) => unawaited(load()));
      unawaited(load());
    },
    onCancel: () => subscription?.cancel(),
  );
  return controller.stream;
}
