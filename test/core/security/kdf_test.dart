import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/core/security/kdf.dart';

void main() {
  tearDown(() => Kdf.useBackgroundIsolate = false);

  test('the isolate path derives exactly the same key as the in-process one', () async {
    final salt = List<int>.generate(16, (index) => index * 7);

    Kdf.useBackgroundIsolate = false;
    final inProcess = await Kdf.pbkdf2Sha256(
      password: '123456',
      salt: salt,
      iterations: 2000,
    );
    Kdf.useBackgroundIsolate = true;
    final inIsolate = await Kdf.pbkdf2Sha256(
      password: '123456',
      salt: salt,
      iterations: 2000,
    );

    expect(inProcess, hasLength(32));
    expect(inIsolate, inProcess);
  });

  test('honours the requested output length and differs per password', () async {
    final salt = List<int>.filled(16, 3);

    final short = await Kdf.pbkdf2Sha256(
      password: '111111',
      salt: salt,
      iterations: 1000,
      bits: 128,
    );
    final other = await Kdf.pbkdf2Sha256(
      password: '222222',
      salt: salt,
      iterations: 1000,
      bits: 128,
    );

    expect(short, hasLength(16));
    expect(other, isNot(short));
  });
}
