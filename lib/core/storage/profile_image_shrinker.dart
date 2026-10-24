import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../models/user_profile.dart';

/// Decodes a picked picture, scales it down so its longest side is at most
/// [maxSide] pixels and re-encodes it as PNG (which keeps the transparency of
/// a signature or a stamp). When the PNG is still larger than
/// [maxProfileImageBytes] the size is reduced further, a few times, before
/// giving up and returning the smallest result.
///
/// Throws when [source] is not an image the platform can decode.
Future<Uint8List> shrinkProfileImage(
  Uint8List source, {
  required int maxSide,
}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(source);
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      if (descriptor.width <= 0 || descriptor.height <= 0) {
        throw const FormatException('Empty image.');
      }
      var result = await _encode(descriptor, maxSide);
      for (final smaller in <int>[384, 256, 160]) {
        if (result.length <= maxProfileImageBytes || smaller >= maxSide) break;
        result = await _encode(descriptor, smaller);
      }
      return result;
    } finally {
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
}

Future<Uint8List> _encode(ui.ImageDescriptor descriptor, int maxSide) async {
  final scale = math.min(
    1.0,
    maxSide / math.max(descriptor.width, descriptor.height),
  );
  final codec = await descriptor.instantiateCodec(
    targetWidth: math.max(1, (descriptor.width * scale).round()),
    targetHeight: math.max(1, (descriptor.height * scale).round()),
  );
  try {
    final frame = await codec.getNextFrame();
    try {
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        throw const FormatException('Could not encode the image.');
      }
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
  }
}
