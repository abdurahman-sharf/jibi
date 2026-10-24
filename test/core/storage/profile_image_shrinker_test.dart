import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/core/models/user_profile.dart';
import 'package:jibi/core/storage/profile_image_shrinker.dart';

/// A PNG of [width]x[height] with a transparent left half and an opaque red
/// right half.
Future<Uint8List> _halfTransparent(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(width / 2, 0, width / 2, height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFFFF0000),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

Future<({int width, int height})> _size(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  final size = (width: descriptor.width, height: descriptor.height);
  descriptor.dispose();
  buffer.dispose();
  return size;
}

Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  codec.dispose();
  return frame.image;
}

void main() {
  testWidgets('a large picture is scaled down to the limit, keeping its shape',
      (tester) async {
    await tester.runAsync(() async {
      final source = await _halfTransparent(2000, 1000);

      final shrunk = await shrinkProfileImage(source, maxSide: 512);

      final size = await _size(shrunk);
      expect(size.width, 512);
      expect(size.height, 256);
      expect(shrunk.length, lessThanOrEqualTo(maxProfileImageBytes));
      // Re-encoded as a PNG.
      expect(shrunk.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    });
  });

  testWidgets('transparency survives (a signature or a stamp on a clear page)',
      (tester) async {
    await tester.runAsync(() async {
      final shrunk = await shrinkProfileImage(
        await _halfTransparent(800, 400),
        maxSide: 400,
      );

      final image = await _decode(shrunk);
      final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      int alphaAt(int x, int y) => data.getUint8((y * image.width + x) * 4 + 3);
      // Left half is clear, right half is opaque.
      expect(alphaAt(20, 100), 0);
      expect(alphaAt(image.width - 20, 100), 255);
      image.dispose();
    });
  });

  testWidgets('a small picture is not enlarged', (tester) async {
    await tester.runAsync(() async {
      final shrunk = await shrinkProfileImage(
        await _halfTransparent(64, 32),
        maxSide: 512,
      );

      final size = await _size(shrunk);
      expect(size.width, 64);
      expect(size.height, 32);
    });
  });

  testWidgets('bytes that are not a picture are refused', (tester) async {
    await tester.runAsync(() async {
      await expectLater(
        shrinkProfileImage(Uint8List.fromList([1, 2, 3, 4]), maxSide: 512),
        throwsA(anything),
      );
    });
  });

  testWidgets('a tall picture is limited by its height', (tester) async {
    await tester.runAsync(() async {
      final shrunk = await shrinkProfileImage(
        await _halfTransparent(300, 1500),
        maxSide: 600,
      );

      final size = await _size(shrunk);
      expect(size.height, 600);
      expect(size.width, 120);
    });
  });
}
