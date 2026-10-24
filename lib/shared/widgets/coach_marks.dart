import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'jibi_design.dart';

/// One hint of a tour: which widget it points at and what it says.
class CoachStep {
  const CoachStep({
    required this.target,
    required this.title,
    required this.message,
  });

  /// Key of the widget to highlight. A step whose widget is not on screen when
  /// the tour starts is left out.
  final GlobalKey target;
  final String title;
  final String message;
}

Rect? _screenRect(GlobalKey key, Size screen) {
  final context = key.currentContext;
  if (context == null) return null;
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize) return null;
  final rect = box.localToGlobal(Offset.zero) & box.size;
  final visible = rect.intersect(Offset.zero & screen);
  // Off screen, or hidden behind something that clipped it away.
  if (visible.isEmpty || visible.width < 4 || visible.height < 4) return null;
  return visible;
}

/// How a tour ended.
enum CoachTourResult {
  /// The user reached the last hint and confirmed it.
  finished,

  /// Skipped, or dismissed with Back.
  skipped,

  /// None of the widgets was visible, so nothing was shown.
  nothingToShow,
}

/// Runs a tour of coach marks (التلميحات المرئية): the screen is dimmed, the
/// widget of each step is lit and circled by a pulsing ring, and a card says
/// what it does. Steps whose widget is not visible are skipped.
///
/// Completes with how the tour ended.
Future<CoachTourResult> showCoachTour(
  BuildContext context,
  List<CoachStep> steps, {
  String finishLabel = 'فهمت',
}) async {
  final screen = MediaQuery.sizeOf(context);
  final visible = [
    for (final step in steps)
      if (_screenRect(step.target, screen) != null) step,
  ];
  if (visible.isEmpty) return CoachTourResult.nothingToShow;
  final finished = await Navigator.of(context, rootNavigator: true).push<bool>(
    PageRouteBuilder<bool>(
      opaque: false,
      barrierDismissible: false,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 250),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (routeContext, _, _) =>
          _CoachOverlay(steps: visible, finishLabel: finishLabel),
      transitionsBuilder: (context, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
  return finished == true ? CoachTourResult.finished : CoachTourResult.skipped;
}

class _CoachOverlay extends StatefulWidget {
  const _CoachOverlay({required this.steps, required this.finishLabel});

  final List<CoachStep> steps;
  final String finishLabel;

  @override
  State<_CoachOverlay> createState() => _CoachOverlayState();
}

class _CoachOverlayState extends State<_CoachOverlay>
    with TickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();
  late final AnimationController _move = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );
  int _index = 0;
  Rect? _from;
  Rect? _to;

  CoachStep get _step => widget.steps[_index];
  bool get _isLast => _index == widget.steps.length - 1;

  @override
  void dispose() {
    _pulse.dispose();
    _move.dispose();
    super.dispose();
  }

  Rect? _measure() {
    final screen = MediaQuery.sizeOf(context);
    return _screenRect(_step.target, screen);
  }

  /// Measured lazily so the first frame already knows where the widget is and
  /// a rotation or keyboard change re-measures on the next step.
  Rect get _current {
    final target = _to ?? _measure() ?? Rect.zero;
    final from = _from;
    if (from == null || !_move.isAnimating) return target;
    return Rect.lerp(from, target, Curves.easeOutCubic.transform(_move.value))!;
  }

  void _go(int next) {
    final previous = _to ?? _measure();
    setState(() {
      _index = next;
      _from = previous;
      _to = _measure();
    });
    _move.forward(from: 0);
  }

  void _advance() {
    if (_isLast) {
      Navigator.of(context).pop(true);
      return;
    }
    // Skip steps whose widget went away since the tour started.
    var next = _index + 1;
    while (next < widget.steps.length &&
        _screenRect(widget.steps[next].target, MediaQuery.sizeOf(context)) ==
            null) {
      next++;
    }
    if (next >= widget.steps.length) {
      Navigator.of(context).pop(true);
      return;
    }
    _go(next);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    _to ??= _measure();
    final colors = Theme.of(context).colorScheme;
    // Back pops the route, which counts as skipping the tour.
    return Material(
      type: MaterialType.transparency,
      child: AnimatedBuilder(
        animation: Listenable.merge([_pulse, _move]),
        builder: (context, _) {
          final hole = _current.inflate(6);
          final above = hole.center.dy > size.height * 0.55;
          final cardWidth = math.min(size.width - 32, 340.0);
          final left = (hole.center.dx - cardWidth / 2)
              .clamp(16.0, math.max(16.0, size.width - cardWidth - 16))
              .toDouble();
          final arrowX = (hole.center.dx - left)
              .clamp(24.0, cardWidth - 24)
              .toDouble();
          final bounce = math.sin(_pulse.value * 2 * math.pi) * 4;
          return Stack(
            key: const Key('coach-overlay'),
            children: [
              // Blocks taps on the page underneath while the tour runs.
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  child: CustomPaint(
                    painter: _ScrimPainter(
                      hole: hole,
                      pulse: _pulse.value,
                      ring: JibiColors.gold,
                    ),
                  ),
                ),
              ),
              Positioned(
                left: left,
                width: cardWidth,
                top: above ? null : hole.bottom + 14 + bounce.abs(),
                bottom: above
                    ? size.height - hole.top + 14 + bounce.abs()
                    : null,
                child: Column(
                  key: Key('coach-card-$_index'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!above)
                      _Arrow(x: arrowX, up: true, color: colors.surface),
                    // A thin outline instead of a shadow: a shadow on the dark
                    // scrim only makes a heavy black rim.
                    Material(
                      color: colors.surface,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                        side: BorderSide(
                          color: colors.primary.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _step.title,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                Text(
                                  '${_index + 1} / ${widget.steps.length}',
                                  key: const Key('coach-counter'),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: context.jibiMuted,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              _step.message,
                              style: TextStyle(
                                fontSize: 13.5,
                                height: 1.5,
                                color: context.jibiMuted,
                              ),
                            ),
                            const SizedBox(height: 8),
                            // Side by side when they fit, stacked with large text.
                            OverflowBar(
                              alignment: _isLast
                                  ? MainAxisAlignment.end
                                  : MainAxisAlignment.spaceBetween,
                              overflowAlignment: OverflowBarAlignment.end,
                              children: [
                                if (!_isLast)
                                  TextButton(
                                    key: const Key('coach-skip'),
                                    onPressed: () =>
                                        Navigator.of(context).pop(false),
                                    child: const Text('تخطي'),
                                  ),
                                FilledButton(
                                  key: const Key('coach-next'),
                                  onPressed: _advance,
                                  child: Text(
                                    _isLast ? widget.finishLabel : 'التالي',
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (above)
                      _Arrow(x: arrowX, up: false, color: colors.surface),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The little triangle joining the card to the lit widget.
class _Arrow extends StatelessWidget {
  const _Arrow({required this.x, required this.up, required this.color});

  final double x;
  final bool up;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 12,
    width: double.infinity,
    child: CustomPaint(
      painter: _ArrowPainter(x: x, up: up, color: color),
    ),
  );
}

class _ArrowPainter extends CustomPainter {
  const _ArrowPainter({required this.x, required this.up, required this.color});

  final double x;
  final bool up;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    if (up) {
      path
        ..moveTo(x - 10, size.height)
        ..lineTo(x, 0)
        ..lineTo(x + 10, size.height);
    } else {
      path
        ..moveTo(x - 10, 0)
        ..lineTo(x, size.height)
        ..lineTo(x + 10, 0);
    }
    canvas.drawPath(path..close(), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_ArrowPainter old) =>
      old.x != x || old.up != up || old.color != color;
}

/// The dimmed page with a rounded hole over the widget, and a pulsing ring.
class _ScrimPainter extends CustomPainter {
  const _ScrimPainter({
    required this.hole,
    required this.pulse,
    required this.ring,
  });

  final Rect hole;
  final double pulse;
  final Color ring;

  @override
  void paint(Canvas canvas, Size size) {
    final rounded = RRect.fromRectAndRadius(hole, const Radius.circular(16));
    final scrim = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()..addRRect(rounded),
    );
    canvas.drawPath(
      scrim,
      Paint()..color = Colors.black.withValues(alpha: 0.74),
    );
    // A steady ring plus a wave that grows and fades.
    canvas.drawRRect(
      rounded,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = ring,
    );
    final wave = Curves.easeOut.transform(pulse);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        hole.inflate(4 + wave * 14),
        Radius.circular(16 + wave * 10),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = ring.withValues(alpha: (1 - wave) * 0.85),
    );
  }

  @override
  bool shouldRepaint(_ScrimPainter old) =>
      old.hole != hole || old.pulse != pulse || old.ring != ring;
}
