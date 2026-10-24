import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth_android/local_auth_android.dart';

import '../errors/app_exception.dart';
import '../../features/credentials/domain/clipboard.dart';
import 'screen_protection.dart';
import 'secure_key_store.dart';

/// Android secure-storage implementation for encryption material and PIN
/// verifiers. Values are base64 transport encoding, never text secrets.
final class FlutterSecureKeyStore implements SecureKeyStore {
  FlutterSecureKeyStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          FlutterSecureStorage(
            aOptions: const AndroidOptions(
              resetOnError: false,
              // Preserve existing secrets when flutter_secure_storage changes
              // its Android cipher defaults between application versions.
              migrateOnAlgorithmChange: true,
            ),
          );

  final FlutterSecureStorage _storage;

  @override
  Future<Uint8List?> read(String key) async {
    try {
      final value = await _storage.read(key: key);
      return value == null
          ? null
          : Uint8List.fromList(base64Url.decode(base64Url.normalize(value)));
    } on Object catch (error) {
      throw SecurityException(
        code: 'secure_storage_read_failed',
        userMessage: 'تعذر قراءة بيانات الحماية بأمان.',
        cause: error,
      );
    }
  }

  @override
  Future<void> write(String key, Uint8List value) async {
    try {
      await _storage.write(key: key, value: base64UrlEncode(value));
    } on Object catch (error) {
      throw SecurityException(
        code: 'secure_storage_write_failed',
        userMessage: 'تعذر حفظ بيانات الحماية بأمان.',
        cause: error,
      );
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } on Object catch (error) {
      throw SecurityException(
        code: 'secure_storage_delete_failed',
        userMessage: 'تعذر تحديث بيانات الحماية بأمان.',
        cause: error,
      );
    }
  }
}

final class LocalAuthBiometricAuthenticator
    implements BiometricAuthenticator, DeviceIdentityVerifier {
  LocalAuthBiometricAuthenticator({LocalAuthentication? localAuthentication})
    : _localAuthentication = localAuthentication ?? LocalAuthentication();

  final LocalAuthentication _localAuthentication;

  /// The system prompt takes its own words from these; the defaults are
  /// English (or whatever locale the plugin picks up).
  static const _promptMessages = [
    AndroidAuthMessages(
      signInTitle: 'تأكيد الهوية',
      signInHint: 'المس مستشعر البصمة',
      cancelButton: 'إلغاء',
    ),
  ];

  @override
  Future<bool> authenticate({required String reason}) async {
    try {
      if (!await canAuthenticate()) {
        return false;
      }
      return await _localAuthentication.authenticate(
        localizedReason: reason,
        authMessages: _promptMessages,
        biometricOnly: true,
        sensitiveTransaction: true,
        persistAcrossBackgrounding: true,
      );
    } on Object {
      // local_auth reports cancellation, lockout and "not enrolled" as
      // LocalAuthException; every failure simply means "not authenticated".
      return false;
    }
  }

  /// True when a biometric is enrolled or the phone has a screen lock.
  @override
  Future<bool> canVerifyIdentity() async {
    try {
      return await _localAuthentication.isDeviceSupported();
    } on Object {
      return false;
    }
  }

  /// One system prompt: the fingerprint, with the screen lock as its fallback.
  @override
  Future<bool> verifyIdentity({required String reason}) async {
    try {
      if (!await canVerifyIdentity()) {
        return false;
      }
      return await _localAuthentication.authenticate(
        localizedReason: reason,
        authMessages: _promptMessages,
        biometricOnly: false,
        sensitiveTransaction: true,
        persistAcrossBackgrounding: true,
      );
    } on Object {
      return false;
    }
  }

  /// True only when at least one biometric is enrolled. `canCheckBiometrics`
  /// is true for any device with hardware, even with nothing enrolled.
  @override
  Future<bool> canAuthenticate() async {
    try {
      return (await _localAuthentication.getAvailableBiometrics()).isNotEmpty;
    } on Object {
      return false;
    }
  }
}

/// Uses Android's FLAG_SECURE. A platform failure is surfaced to settings
/// rather than being ignored, so the user never receives a false guarantee.
final class FlutterScreenProtection implements ScreenProtection {
  static const _channel = MethodChannel('com.jibi.jibi/screen_protection');

  @override
  Future<void> setEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod<void>('setEnabled', <String, bool>{
        'enabled': enabled,
      });
    } on MissingPluginException {
      // Some platforms and test hosts do not expose the Android channel.
      // The app remains usable; Android production builds register it.
      return;
    } on PlatformException catch (error) {
      throw SecurityException(
        code: 'screen_protection_failed',
        userMessage: 'تعذر تطبيق حماية لقطات الشاشة.',
        cause: error,
      );
    }
  }
}

final class FlutterClipboardPort implements ClipboardPort {
  const FlutterClipboardPort();

  @override
  Future<String?> readText() async =>
      (await Clipboard.getData('text/plain'))?.text;

  @override
  Future<void> writeText(String value) =>
      Clipboard.setData(ClipboardData(text: value));
}
