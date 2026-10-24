import 'dart:async';

import 'package:flutter/widgets.dart';

import '../shared/widgets/coach_marks.dart';

/// Ids of the hint tours, remembered in the settings once shown.
abstract final class CoachTourIds {
  static const String home = 'home';
  static const String accounts = 'accounts';
  static const String account = 'account';
}

/// Decides when a hint tour may appear: the hints are switched on, this tour
/// has not been shown yet and no other tour is running. Owned by the app.
final class CoachTourHost {
  CoachTourHost({
    required this.isEnabled,
    required this.isSeen,
    required this.markSeen,
    this.delay = const Duration(milliseconds: 700),
    this.retryDelay = const Duration(milliseconds: 500),
    this.attempts = 4,
  });

  final bool Function() isEnabled;
  final bool Function(String id) isSeen;
  final Future<void> Function(String id) markSeen;

  /// Lets the screen and its transition settle before the first hint, so the
  /// widgets are where the tour will measure them.
  final Duration delay;

  /// A screen that loads its data first (an account's statement) may not have
  /// its buttons yet after [delay]: the tour looks again up to [attempts]
  /// times, [retryDelay] apart, before giving up until the next visit.
  final Duration retryDelay;
  final int attempts;

  bool _running = false;

  bool get isRunning => _running;

  /// Shows the tour [id] once. Nothing happens while another tour runs, when
  /// hints are off or when the tour was already seen; a tour that could not
  /// find any of its widgets is not counted as seen, so it tries again later.
  ///
  /// [stillApplicable] is asked once more after the short wait: a screen that
  /// is no longer the one in front (another tab was opened meanwhile) must not
  /// get its hints drawn over the wrong page.
  Future<CoachTourResult?> startOnce(
    BuildContext context,
    String id,
    List<CoachStep> Function() steps, {
    bool Function()? stillApplicable,
  }) async {
    if (_running || !isEnabled() || isSeen(id)) return null;
    _running = true;
    try {
      var result = CoachTourResult.nothingToShow;
      for (var attempt = 0; attempt < attempts; attempt++) {
        await Future<void>.delayed(attempt == 0 ? delay : retryDelay);
        if (!context.mounted || !isEnabled() || isSeen(id)) return null;
        if (stillApplicable != null && !stillApplicable()) return null;
        result = await showCoachTour(context, steps());
        if (result != CoachTourResult.nothingToShow) {
          await markSeen(id);
          return result;
        }
      }
      return result;
    } finally {
      _running = false;
    }
  }
}

/// Hands the [CoachTourHost] to the screens. Without it (tests, previews) no
/// tour ever appears.
class CoachScope extends InheritedWidget {
  const CoachScope({required this.host, required super.child, super.key});

  final CoachTourHost host;

  static CoachTourHost? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<CoachScope>()?.host;

  @override
  bool updateShouldNotify(CoachScope oldWidget) => oldWidget.host != host;
}

extension CoachTourContext on BuildContext {
  /// Starts the tour [id] after the current frame, if the app runs tours and
  /// this screen is the one in front (a hidden tab does not count).
  ///
  /// Call it from `didChangeDependencies`: a tab's screen is built before it
  /// is visited, and it depends on `TickerMode`, which flips when the tab is
  /// selected.
  void startTourOnce(String id, List<CoachStep> Function() steps) {
    final host = CoachScope.maybeOf(this);
    if (host == null || !TickerMode.valuesOf(this).enabled) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        host.startOnce(
          this,
          id,
          steps,
          stillApplicable: () => mounted && TickerMode.valuesOf(this).enabled,
        ),
      );
    });
  }
}
