import 'package:flutter/widgets.dart';

/// Runs [action] while marking the app as launching an external Android
/// activity (file picker, camera, share sheet), so the lifecycle lock does not
/// mistake it for the user leaving Jibi.
///
/// Pass `holdUntilResumed: true` for flows that return before the other
/// activity actually appears (share sheets): the guard then stays on until the
/// app comes back to the foreground.
typedef ExternalActivityRunner =
    Future<T> Function<T>(
      Future<T> Function() action, {
      bool holdUntilResumed,
    });

/// Exposes the application's [ExternalActivityRunner] to any page that starts
/// a platform activity, without threading it through every constructor.
///
/// Without a scope (standalone pages in widget tests) the action simply runs.
class ExternalActivityScope extends InheritedWidget {
  const ExternalActivityScope({
    required this.run,
    required super.child,
    this.release,
    super.key,
  });

  final ExternalActivityRunner run;

  /// Ends a `holdUntilResumed` guard at once. For flows that learn the other
  /// activity never appeared (nothing could handle the request): without it
  /// the app would stay unlockable by the background timer until the guard
  /// times out.
  final VoidCallback? release;

  static ExternalActivityRunner of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ExternalActivityScope>()?.run ??
      _passthrough;

  static VoidCallback releaseOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ExternalActivityScope>()?.release ??
      _noop;

  static void _noop() {}

  static Future<T> _passthrough<T>(
    Future<T> Function() action, {
    bool holdUntilResumed = false,
  }) => action();

  @override
  bool updateShouldNotify(ExternalActivityScope oldWidget) =>
      run != oldWidget.run || release != oldWidget.release;
}
