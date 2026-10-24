import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A chat bubble with a handset inside it, the way WhatsApp is drawn. Material
/// has no WhatsApp icon and the app carries no icon package, so it is drawn
/// here: an outlined bubble whose tail points to the lower left (it is never
/// mirrored for right-to-left) around Material's handset.
class WhatsAppGlyph extends StatelessWidget {
  const WhatsAppGlyph({this.size = 28, this.color = Colors.white, super.key});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: Stack(
      alignment: Alignment.center,
      children: [
        CustomPaint(size: Size.square(size), painter: _BubblePainter(color)),
        // Nudged up a little: the bubble's tail takes the lower part.
        Transform.translate(
          offset: Offset(0, -size * 0.02),
          child: Icon(Icons.phone, size: size * 0.46, color: color),
        ),
      ],
    ),
  );
}

class _BubblePainter extends CustomPainter {
  const _BubblePainter(this.color);

  final Color color;

  static double _radians(double degrees) => degrees * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    // Drawn on a 24 x 24 grid and scaled.
    canvas.scale(size.width / 24, size.height / 24);
    const centre = Offset(12, 11.4);
    const radius = 8.5;
    // The bubble is open where the tail joins it (about 112 to 162 degrees,
    // measured clockwise from the right), so the arc runs the long way round.
    final path = Path()
      ..arcTo(
        Rect.fromCircle(center: centre, radius: radius),
        _radians(112),
        -_radians(310),
        true,
      )
      ..lineTo(3.2, 21.2)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.9
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(_BubblePainter oldDelegate) => oldDelegate.color != color;
}
