import 'security_service.dart';

enum AppLifecycleEvent { foregrounded, backgrounded }

abstract interface class AppLockPolicy {
  bool shouldLock(Duration backgroundDuration);
}

final class TimeoutAppLockPolicy implements AppLockPolicy {
  const TimeoutAppLockPolicy(this.timeout);

  final Duration timeout;

  @override
  bool shouldLock(Duration backgroundDuration) =>
      (backgroundDuration.isNegative ? Duration.zero : backgroundDuration) >=
      timeout;
}

/// Applies [AppLockPolicy] to lifecycle events. The events are fed in by the
/// caller so this class stays independent from Flutter bindings.
final class AppLockController {
  AppLockController({
    required this.securityService,
    required this.policy,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final SecurityService securityService;
  final AppLockPolicy policy;
  final DateTime Function() _clock;
  DateTime? _backgroundedAt;

  Future<void> handle(AppLifecycleEvent event) async {
    if (event == AppLifecycleEvent.backgrounded) {
      _backgroundedAt ??= _clock();
      return;
    }
    final backgroundedAt = _backgroundedAt;
    _backgroundedAt = null;
    if (backgroundedAt != null &&
        policy.shouldLock(_clock().difference(backgroundedAt))) {
      await securityService.lock();
    }
  }
}
