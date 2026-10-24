import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jibi/core/models/credential.dart';
import 'package:jibi/core/repositories/repositories.dart';
import 'package:jibi/core/security/security.dart';
import 'package:jibi/features/credentials/credentials.dart';

void main() {
  test(
    'password generator meets selected categories without weakening length',
    () {
      final password = PasswordGenerator().generate(
        const PasswordGenerationOptions(
          length: 20,
          includeUppercase: true,
          includeLowercase: true,
          includeNumbers: true,
          includeSymbols: true,
        ),
      );

      expect(password, hasLength(20));
      expect(password, matches(RegExp(r'[A-Z]')));
      expect(password, matches(RegExp(r'[a-z]')));
      expect(password, matches(RegExp(r'[0-9]')));
      expect(password, matches(RegExp(r'[!@#$%^&*()\-_=+\[\]{}:,.?]')));
    },
  );

  test(
    'clipboard clears its own secret but preserves newer clipboard content',
    () async {
      final clipboard = _MemoryClipboard();
      final scheduler = _ManualClipboardScheduler();
      final controller = SensitiveClipboardController(
        clipboard: clipboard,
        scheduler: scheduler,
      );

      await controller.copySecret(
        'first-secret',
        clearAfter: const Duration(seconds: 30),
      );
      await clipboard.writeText('user-copied-text');
      await scheduler.runLatest();
      expect(clipboard.value, 'user-copied-text');

      await controller.copySecret(
        'second-secret',
        clearAfter: const Duration(seconds: 30),
      );
      await scheduler.runLatest();
      expect(clipboard.value, isEmpty);
    },
  );

  test(
    'vault encrypts sensitive fields before repository persistence',
    () async {
      final security = AesGcmSecurityService(
        keyStore: _MemorySecureKeyStore(),
        biometricAuthenticator: const _BiometricResult(true),
      );
      await security.initialize(pin: '123456');
      final repository = _CredentialsMemoryRepository();
      final vault = CredentialVaultController(
        repository: repository,
        securityService: security,
        clipboard: SensitiveClipboardController(
          clipboard: _MemoryClipboard(),
          scheduler: _ManualClipboardScheduler(),
        ),
        createId: () => 'credential-1',
        clock: () => DateTime.utc(2026, 1, 1),
      );

      await vault.create(
        const CredentialInput(
          title: 'Email',
          username: 'person@example.com',
          email: 'person@example.com',
          password: 'not-persisted-in-plaintext',
          notes: 'private note',
        ),
      );

      final saved = repository.saved.single;
      expect(saved.passwordEncrypted.value, isNot(contains('not-persisted')));
      expect(
        (await vault.read(saved.id))!.password,
        'not-persisted-in-plaintext',
      );
    },
  );
}

final class _MemoryClipboard implements ClipboardPort {
  String value = '';

  @override
  Future<String?> readText() async => value;

  @override
  Future<void> writeText(String value) async {
    this.value = value;
  }
}

final class _ManualClipboardScheduler implements ClipboardScheduler {
  final List<_ManualTask> _tasks = [];

  @override
  ScheduledTask schedule(Duration delay, Future<void> Function() action) {
    final task = _ManualTask(action);
    _tasks.add(task);
    return task;
  }

  Future<void> runLatest() async => await _tasks.last.run();
}

final class _ManualTask implements ScheduledTask {
  _ManualTask(this._action);

  final Future<void> Function() _action;
  bool _cancelled = false;

  @override
  void cancel() => _cancelled = true;

  Future<void> run() async {
    if (!_cancelled) {
      await _action();
    }
  }
}

final class _MemorySecureKeyStore implements SecureKeyStore {
  final Map<String, List<int>> _values = {};

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  Future<Uint8List?> read(String key) async {
    final value = _values[key];
    return value == null ? null : Uint8List.fromList(value);
  }

  @override
  Future<void> write(String key, Uint8List value) async {
    _values[key] = List<int>.from(value);
  }
}

final class _BiometricResult implements BiometricAuthenticator {
  const _BiometricResult(this.result);

  final bool result;

  @override
  Future<bool> authenticate({required String reason}) async => result;

  @override
  Future<bool> canAuthenticate() async => true;
}

final class _CredentialsMemoryRepository implements CredentialsRepository {
  final List<Credential> saved = [];

  @override
  Future<void> deleteCredential(String id) async {
    saved.removeWhere((credential) => credential.id == id);
  }

  @override
  Future<Credential?> findCredential(String id) async {
    for (final credential in saved) {
      if (credential.id == id) {
        return credential;
      }
    }
    return null;
  }

  @override
  Future<void> saveCredential(Credential credential) async {
    saved.removeWhere((existing) => existing.id == credential.id);
    saved.add(credential);
  }

  @override
  Stream<List<Credential>> watchCredentials({
    String? query,
    String? categoryId,
    bool favoritesOnly = false,
  }) => Stream.value(List<Credential>.unmodifiable(saved));
}
