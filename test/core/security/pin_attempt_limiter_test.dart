import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jibi/core/errors/app_exception.dart';
import 'package:jibi/core/security/pin_attempt_limiter.dart';
import 'package:jibi/core/security/security.dart';

void main() {
  group('PinAttemptLimiter policy', () {
    late _MemoryStore store;
    late DateTime now;
    late PinAttemptLimiter limiter;

    setUp(() {
      store = _MemoryStore();
      now = DateTime.utc(2026, 9, 21, 12);
      limiter = PinAttemptLimiter(keyStore: store, clock: () => now);
    });

    test('four wrong PINs cost nothing, the fifth pauses for 30 seconds', () async {
      for (var attempt = 1; attempt <= 4; attempt++) {
        expect(await limiter.recordFailure(), isNull, reason: 'attempt $attempt');
        expect(await limiter.remaining(), isNull);
      }
      expect(await limiter.recordFailure(), const Duration(seconds: 30));
      expect(await limiter.remaining(), const Duration(seconds: 30));
    });

    test('lockouts escalate and stay at one hour', () async {
      for (var i = 0; i < PinAttemptLimiter.freeAttempts; i++) {
        await limiter.recordFailure();
      }
      final waits = <Duration?>[];
      for (var i = 0; i < 7; i++) {
        waits.add(await limiter.recordFailure());
      }
      expect(waits, const [
        Duration(seconds: 30),
        Duration(minutes: 1),
        Duration(minutes: 5),
        Duration(minutes: 15),
        Duration(minutes: 60),
        Duration(minutes: 60),
        Duration(minutes: 60),
      ]);
    });

    test('the wait shrinks with time and ends', () async {
      for (var i = 0; i < 5; i++) {
        await limiter.recordFailure();
      }
      now = now.add(const Duration(seconds: 12));
      expect(await limiter.remaining(), const Duration(seconds: 18));
      now = now.add(const Duration(seconds: 18));
      expect(await limiter.remaining(), isNull);
    });

    test('the next failure after a lockout escalates instead of starting over', () async {
      for (var i = 0; i < 5; i++) {
        await limiter.recordFailure();
      }
      now = now.add(const Duration(seconds: 31));
      expect(await limiter.remaining(), isNull);
      expect(await limiter.recordFailure(), const Duration(minutes: 1));
    });

    test('setting the clock back never shortens a wait', () async {
      for (var i = 0; i < 5; i++) {
        await limiter.recordFailure();
      }
      now = now.subtract(const Duration(days: 2));
      expect(await limiter.remaining(), const Duration(seconds: 30));
    });

    test('reset forgets every failure', () async {
      for (var i = 0; i < 5; i++) {
        await limiter.recordFailure();
      }
      await limiter.reset();
      expect(await limiter.remaining(), isNull);
      expect(store.values, isEmpty);
      for (var i = 0; i < PinAttemptLimiter.freeAttempts; i++) {
        expect(await limiter.recordFailure(), isNull);
      }
    });

    test('closing the app does not reset the count', () async {
      for (var i = 0; i < 5; i++) {
        await limiter.recordFailure();
      }
      final reopened = PinAttemptLimiter(keyStore: store, clock: () => now);
      expect(await reopened.remaining(), const Duration(seconds: 30));
    });

    test('a damaged record never locks the owner out', () async {
      for (final junk in ['not json', '[]', '{"failures":"x"}', '{}']) {
        store.values[PinAttemptLimiter.storeKey] = Uint8List.fromList(
          utf8.encode(junk),
        );
        expect(await limiter.remaining(), isNull, reason: junk);
      }
      store.values[PinAttemptLimiter.storeKey] = Uint8List.fromList([0xff, 0xfe]);
      expect(await limiter.remaining(), isNull);
    });
  });

  group('wait wording', () {
    test('describes seconds, minutes and an hour in Arabic', () {
      expect(describeWait(const Duration(seconds: 30)), '30 ثانية');
      expect(describeWait(const Duration(milliseconds: 400)), '1 ثانية');
      expect(describeWait(const Duration(seconds: 61)), 'دقيقتين');
      expect(describeWait(const Duration(minutes: 1)), 'دقيقة');
      expect(describeWait(const Duration(minutes: 5)), '5 دقائق');
      expect(describeWait(const Duration(minutes: 15)), '15 دقيقة');
      expect(describeWait(const Duration(minutes: 60)), 'ساعة');
      expect(
        pinLockoutMessage(const Duration(minutes: 5)),
        'محاولات كثيرة خاطئة. أعد المحاولة بعد 5 دقائق.',
      );
    });
  });

  group('AesGcmSecurityService', () {
    test(
      'pauses PIN attempts after five wrong PINs, then recovers',
      () async {
        var now = DateTime.utc(2026, 9, 21, 12);
        final store = _MemoryStore();
        final service = AesGcmSecurityService(
          keyStore: store,
          biometricAuthenticator: const _Fingerprint(),
          clock: () => now,
        );
        await service.initialize(pin: '123456');
        await service.lock();

        for (var attempt = 1; attempt <= 4; attempt++) {
          final result = await service.unlockWithPin('000000');
          expect(result.reason, 'invalid_pin', reason: 'attempt $attempt');
          expect(result.retryAfter, isNull);
        }
        final fifth = await service.unlockWithPin('000000');
        expect(fifth.authenticated, isFalse);
        expect(fifth.reason, 'pin_locked_out');
        expect(fifth.retryAfter, const Duration(seconds: 30));

        // While paused even the right PIN gets no answer.
        final paused = await service.unlockWithPin('123456');
        expect(paused.authenticated, isFalse);
        expect(paused.reason, 'pin_locked_out');
        await expectLater(
          service.verifyPin('123456'),
          throwsA(
            isA<SecurityException>().having(
              (error) => error.code,
              'code',
              'pin_locked_out',
            ),
          ),
        );

        // The fingerprint is not a guess: it still opens the app, but changing
        // the PIN (which needs the current one) stays paused.
        expect((await service.authenticateBiometrically()).authenticated, isTrue);
        await expectLater(
          service.changePin(currentPin: '123456', newPin: '654321'),
          throwsA(
            isA<SecurityException>().having(
              (error) => error.userMessage,
              'message',
              contains('محاولات كثيرة'),
            ),
          ),
        );
        await service.lock();

        now = now.add(const Duration(seconds: 31));
        expect((await service.unlockWithPin('123456')).authenticated, isTrue);

        // A correct PIN starts the count again.
        await service.lock();
        expect((await service.unlockWithPin('000000')).reason, 'invalid_pin');
      },
      timeout: const Timeout(Duration(minutes: 4)),
    );
  });
}

final class _MemoryStore implements SecureKeyStore {
  final Map<String, Uint8List> values = {};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<Uint8List?> read(String key) async {
    final value = values[key];
    return value == null ? null : Uint8List.fromList(value);
  }

  @override
  Future<void> write(String key, Uint8List value) async {
    values[key] = Uint8List.fromList(value);
  }
}

final class _Fingerprint implements BiometricAuthenticator {
  const _Fingerprint();

  @override
  Future<bool> authenticate({required String reason}) async => true;

  @override
  Future<bool> canAuthenticate() async => true;
}
