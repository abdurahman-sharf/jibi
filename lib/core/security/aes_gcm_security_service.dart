import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../diagnostics/phase_trace.dart';
import '../errors/app_exception.dart';
import '../models/encrypted_value.dart';
import 'pin_attempt_limiter.dart';
import 'pin_verifier.dart';
import 'secure_key_store.dart';
import 'security_primitives.dart';
import 'security_service.dart';

/// AES-256-GCM implementation whose long-lived material is delegated to
/// [SecureKeyStore]. It has no storage fallback and never serializes plaintext.
final class AesGcmSecurityService
    implements SecurityService, DeviceVerifiedPinReset, BiometricCapability {
  AesGcmSecurityService({
    required this.keyStore,
    required this.biometricAuthenticator,
    DateTime Function()? clock,
  }) : _attempts = PinAttemptLimiter(keyStore: keyStore, clock: clock),
       _clock = clock ?? DateTime.now;

  /// How long a confirmed device check allows one PIN reset.
  static const pinResetWindow = Duration(minutes: 5);

  static const _dataKeyStoreKey = 'jibi.security.data-key.v1';
  static const _pinVerifierStoreKey = 'jibi.security.pin-verifier.v1';
  static const _recoveryPendingStoreKey = 'jibi.security.recovery-pending.v1';
  static const _envelopeVersion = 1;
  static const _nonceLength = 12;
  static const _tagLength = 16;
  static const _recoverySaltLength = 16;
  static const _recoveryIterations = 600000;

  final SecureKeyStore keyStore;
  final BiometricAuthenticator biometricAuthenticator;
  final PinAttemptLimiter _attempts;
  final DateTime Function() _clock;
  final AesGcm _cipher = AesGcm.with256bits();
  final StreamController<AppLockState> _lockStates =
      StreamController<AppLockState>.broadcast();
  SecretKey? _activeDataKey;
  bool _locked = true;

  /// Set by a confirmed [verifyDeviceIdentity]; kept in memory only, so a
  /// restart of the app always asks again.
  DateTime? _pinResetAllowedUntil;

  @override
  Stream<AppLockState> get lockStates => _lockStates.stream;

  @override
  Future<bool> get isInitialized async {
    final verifier = await keyStore.read(_pinVerifierStoreKey);
    final dataKey = await keyStore.read(_dataKeyStoreKey);
    final pending = await keyStore.read(_recoveryPendingStoreKey);
    return verifier != null && dataKey != null && pending == null;
  }

  @override
  Future<bool> get isRecoverySetupPending async =>
      await keyStore.read(_recoveryPendingStoreKey) != null;

  @override
  Future<void> initialize({required String pin}) async {
    if (await _hasAnyMaterial()) {
      throw const SecurityException(
        code: 'security_already_initialized',
        userMessage: 'تم إعداد الحماية مسبقاً.',
      );
    }
    final verifier = await PinVerifier.create(pin);
    final dataKey = await _cipher.newSecretKey();
    final dataKeyBytes = Uint8List.fromList(await dataKey.extractBytes());
    await keyStore.write(_dataKeyStoreKey, dataKeyBytes);
    await keyStore.write(_pinVerifierStoreKey, verifier.toBytes());
    await _attempts.reset();
    _activeDataKey = dataKey;
    _setLockState(AppLockState.unlocked);
  }

  @override
  Future<void> completeRecoverySetup({required String pin}) async {
    _requireUnlocked();
    if (!await isRecoverySetupPending ||
        await keyStore.read(_dataKeyStoreKey) == null) {
      throw const SecurityException(
        code: 'recovery_not_pending',
        userMessage: 'لا توجد عملية استعادة تحتاج إلى إكمال.',
      );
    }
    final verifier = await PinVerifier.create(pin);
    await keyStore.write(_pinVerifierStoreKey, verifier.toBytes());
    await keyStore.delete(_recoveryPendingStoreKey);
    await _attempts.reset();
  }

  @override
  Future<AuthenticationResult> unlockWithPin(String pin) async {
    final trace = PhaseTrace('unlockWithPin');
    try {
      // The three keys `isInitialized` also reads, fetched together instead
      // of sequentially (verifier was previously read twice, data key twice)
      // — same three conditions, same result, fewer secure-storage round
      // trips before the PBKDF2 check even starts.
      final reads = await trace.measure(
        'Secure storage (verifier + data key + recovery flag)',
        () => Future.wait(<Future<Uint8List?>>[
          keyStore.read(_pinVerifierStoreKey),
          keyStore.read(_dataKeyStoreKey),
          keyStore.read(_recoveryPendingStoreKey),
        ]),
      );
      final encodedVerifier = reads[0];
      final dataKeyBytes = reads[1];
      final recoveryPending = reads[2];
      if (encodedVerifier == null ||
          dataKeyBytes == null ||
          recoveryPending != null) {
        return const AuthenticationResult(
          authenticated: false,
          reason: 'not_initialized',
        );
      }
      final paused = await trace.measure(
        'Attempt lockout check',
        () => _attempts.remaining(),
      );
      if (paused != null) {
        // No PBKDF2 while paused: guessing gets no answer at all.
        return AuthenticationResult(
          authenticated: false,
          reason: 'pin_locked_out',
          retryAfter: paused,
        );
      }
      final verifier = PinVerifier.fromBytes(encodedVerifier);
      final ok = await trace.measure(
        'PBKDF2 verify (${verifier.iterations} iterations)',
        () => verifier.verify(pin),
      );
      if (!ok) {
        final lockout = await trace.measure(
          'Record failed attempt',
          () => _attempts.recordFailure(),
        );
        return AuthenticationResult(
          authenticated: false,
          reason: lockout == null ? 'invalid_pin' : 'pin_locked_out',
          retryAfter: lockout,
        );
      }
      await trace.measure('Reset attempt counter', () => _attempts.reset());
      await trace.measure(
        'Load data key',
        () => _loadActiveDataKey(dataKeyBytes),
      );
      _setLockState(AppLockState.unlocked);
      return const AuthenticationResult(authenticated: true);
    } finally {
      trace.report();
    }
  }

  @override
  Future<bool> verifyPin(String pin) async {
    final encodedVerifier = await keyStore.read(_pinVerifierStoreKey);
    if (encodedVerifier == null) {
      return false;
    }
    await _throwIfPaused();
    if (await PinVerifier.fromBytes(encodedVerifier).verify(pin)) {
      await _attempts.reset();
      return true;
    }
    final lockout = await _attempts.recordFailure();
    if (lockout != null) throw _lockedOut(lockout);
    return false;
  }

  Future<void> _throwIfPaused() async {
    final paused = await _attempts.remaining();
    if (paused != null) throw _lockedOut(paused);
  }

  static SecurityException _lockedOut(Duration retryAfter) =>
      SecurityException(
        code: 'pin_locked_out',
        userMessage: pinLockoutMessage(retryAfter),
      );

  @override
  Future<bool> canUseBiometrics() => biometricAuthenticator.canAuthenticate();

  @override
  Future<AuthenticationResult> authenticateBiometrically() async {
    if (!await isInitialized) {
      return const AuthenticationResult(
        authenticated: false,
        reason: 'not_initialized',
      );
    }
    final authenticated = await biometricAuthenticator.authenticate(
      reason: 'استخدم بصمتك لفتح جيبي أو لتأكيد العملية',
    );
    if (!authenticated) {
      return const AuthenticationResult(
        authenticated: false,
        reason: 'biometric_rejected',
      );
    }
    await _loadActiveDataKey();
    _setLockState(AppLockState.unlocked);
    return const AuthenticationResult(authenticated: true);
  }

  @override
  Future<AuthenticationResult> reauthenticate() => authenticateBiometrically();

  @override
  Future<void> changePin({
    required String currentPin,
    required String newPin,
  }) async {
    _requireUnlocked();
    final verifierBytes = await keyStore.read(_pinVerifierStoreKey);
    if (verifierBytes == null) {
      throw const SecurityException(
        code: 'invalid_current_pin',
        userMessage: 'رمز الدخول الحالي غير صحيح.',
      );
    }
    await _throwIfPaused();
    if (!await PinVerifier.fromBytes(verifierBytes).verify(currentPin)) {
      final lockout = await _attempts.recordFailure();
      if (lockout != null) throw _lockedOut(lockout);
      throw const SecurityException(
        code: 'invalid_current_pin',
        userMessage: 'رمز الدخول الحالي غير صحيح.',
      );
    }
    final verifier = await PinVerifier.create(newPin);
    await keyStore.write(_pinVerifierStoreKey, verifier.toBytes());
    await _attempts.reset();
  }

  @override
  Future<bool> canVerifyDeviceIdentity() async {
    final verifier = biometricAuthenticator;
    return verifier is DeviceIdentityVerifier &&
        await (verifier as DeviceIdentityVerifier).canVerifyIdentity();
  }

  @override
  Future<AuthenticationResult> verifyDeviceIdentity() async {
    _pinResetAllowedUntil = null;
    if (!await isInitialized) {
      return const AuthenticationResult(
        authenticated: false,
        reason: 'not_initialized',
      );
    }
    if (!await canVerifyDeviceIdentity()) {
      return const AuthenticationResult(
        authenticated: false,
        reason: 'device_auth_unavailable',
      );
    }
    final confirmed = await (biometricAuthenticator as DeviceIdentityVerifier)
        .verifyIdentity(reason: 'أكّد هويتك لإنشاء رمز PIN جديد لجيبي');
    if (!confirmed) {
      return const AuthenticationResult(
        authenticated: false,
        reason: 'identity_not_confirmed',
      );
    }
    _pinResetAllowedUntil = _clock().add(pinResetWindow);
    return const AuthenticationResult(authenticated: true);
  }

  @override
  Future<void> resetPin({required String newPin}) async {
    final allowedUntil = _pinResetAllowedUntil;
    // One reset per confirmation, whatever happens next.
    _pinResetAllowedUntil = null;
    if (allowedUntil == null || !_clock().isBefore(allowedUntil)) {
      throw const SecurityException(
        code: 'pin_reset_not_authorized',
        userMessage: 'انتهت مهلة التحقق من الهوية. أعد المحاولة.',
      );
    }
    // Only the PIN verifier changes. The data key is checked first so a reset
    // can never leave a PIN in front of a store that cannot be opened.
    await _loadActiveDataKey();
    final verifier = await PinVerifier.create(newPin);
    await keyStore.write(_pinVerifierStoreKey, verifier.toBytes());
    await _attempts.reset();
    _setLockState(AppLockState.unlocked);
  }

  @override
  Future<void> lock() async {
    _activeDataKey = null;
    _pinResetAllowedUntil = null;
    _setLockState(AppLockState.locked);
  }

  @override
  Future<EncryptedValue> encryptText(String plaintext) async {
    final encrypted = await encryptBytes(
      Uint8List.fromList(utf8.encode(plaintext)),
    );
    return EncryptedValue(
      'v$_envelopeVersion.${base64UrlEncode(encrypted).replaceAll('=', '')}',
    );
  }

  @override
  Future<String> decryptText(EncryptedValue encrypted) async {
    final parts = encrypted.value.split('.');
    if (parts.length != 2 || parts.first != 'v$_envelopeVersion') {
      throw const SecurityException(
        code: 'invalid_encrypted_value',
        userMessage: 'البيانات المشفرة غير صالحة.',
      );
    }
    try {
      final decrypted = await decryptBytes(
        Uint8List.fromList(base64Url.decode(base64Url.normalize(parts.last))),
      );
      return utf8.decode(decrypted, allowMalformed: false);
    } on SecurityException {
      rethrow;
    } on Object catch (error) {
      throw SecurityException(
        code: 'invalid_encrypted_value',
        userMessage: 'البيانات المشفرة غير صالحة.',
        cause: error,
      );
    }
  }

  @override
  Future<Uint8List> encryptBytes(Uint8List plaintext) async {
    final key = _requireUnlocked();
    final nonce = secureRandomBytes(_nonceLength);
    final box = await _cipher.encrypt(plaintext, secretKey: key, nonce: nonce);
    return Uint8List.fromList(<int>[
      _envelopeVersion,
      ...box.nonce,
      ...box.mac.bytes,
      ...box.cipherText,
    ]);
  }

  @override
  Future<Uint8List> decryptBytes(Uint8List ciphertext) async {
    final key = _requireUnlocked();
    if (ciphertext.length < 1 + _nonceLength + _tagLength ||
        ciphertext.first != _envelopeVersion) {
      throw const SecurityException(
        code: 'invalid_ciphertext',
        userMessage: 'البيانات المشفرة غير صالحة.',
      );
    }
    try {
      final nonceStart = 1;
      final tagStart = nonceStart + _nonceLength;
      final encryptedStart = tagStart + _tagLength;
      final clearText = await _cipher.decrypt(
        SecretBox(
          ciphertext.sublist(encryptedStart),
          nonce: ciphertext.sublist(nonceStart, tagStart),
          mac: Mac(ciphertext.sublist(tagStart, encryptedStart)),
        ),
        secretKey: key,
      );
      return Uint8List.fromList(clearText);
    } on Object catch (error) {
      throw SecurityException(
        code: 'ciphertext_authentication_failed',
        userMessage: 'تعذر التحقق من سلامة البيانات المشفرة.',
        cause: error,
      );
    }
  }

  @override
  Future<Uint8List> wrapDataKeyForRecovery(String recoveryPassword) async {
    final dataKey = _requireUnlocked();
    validateBackupPin(recoveryPassword);
    final salt = secureRandomBytes(_recoverySaltLength);
    final wrappingKey = await deriveKeyFromSecret(recoveryPassword, salt, _recoveryIterations);
    final nonce = secureRandomBytes(_nonceLength);
    final box = await _cipher.encrypt(
      await dataKey.extractBytes(),
      secretKey: wrappingKey,
      nonce: nonce,
    );
    return Uint8List.fromList(<int>[
      _envelopeVersion,
      ...salt,
      ...box.nonce,
      ...box.mac.bytes,
      ...box.cipherText,
    ]);
  }

  @override
  Future<void> restoreWrappedDataKey({
    required Uint8List wrappedKey,
    required String recoveryPassword,
  }) async {
    validateBackupPin(recoveryPassword);
    if (await _hasAnyMaterial()) {
      throw const SecurityException(
        code: 'security_already_initialized',
        userMessage: 'لا يمكن الاستعادة فوق بيانات الحماية الحالية.',
      );
    }
    const headerLength = 1 + _recoverySaltLength + _nonceLength + _tagLength;
    if (wrappedKey.length != headerLength + 32 ||
        wrappedKey.first != _envelopeVersion) {
      throw const SecurityException(
        code: 'invalid_recovery_key',
        userMessage: 'ملف الاستعادة غير صالح.',
      );
    }
    try {
      final salt = wrappedKey.sublist(1, 1 + _recoverySaltLength);
      final nonceStart = 1 + _recoverySaltLength;
      final tagStart = nonceStart + _nonceLength;
      final cipherTextStart = tagStart + _tagLength;
      final wrappingKey = await deriveKeyFromSecret(recoveryPassword, salt, _recoveryIterations);
      final rawDataKey = await _cipher.decrypt(
        SecretBox(
          wrappedKey.sublist(cipherTextStart),
          nonce: wrappedKey.sublist(nonceStart, tagStart),
          mac: Mac(wrappedKey.sublist(tagStart, cipherTextStart)),
        ),
        secretKey: wrappingKey,
      );
      if (rawDataKey.length != 32) {
        throw const FormatException('Unexpected data key length.');
      }
      await keyStore.write(_dataKeyStoreKey, Uint8List.fromList(rawDataKey));
      await keyStore.delete(_pinVerifierStoreKey);
      await keyStore.write(_recoveryPendingStoreKey, Uint8List.fromList([1]));
      _activeDataKey = await _cipher.newSecretKeyFromBytes(rawDataKey);
      _setLockState(AppLockState.unlocked);
    } on SecurityException {
      rethrow;
    } on Object catch (error) {
      throw SecurityException(
        code: 'recovery_authentication_failed',
        userMessage: 'تعذر التحقق من كلمة الاستعادة أو البيانات.',
        cause: error,
      );
    }
  }

  Future<bool> _hasAnyMaterial() async =>
      await keyStore.read(_dataKeyStoreKey) != null ||
      await keyStore.read(_pinVerifierStoreKey) != null ||
      await keyStore.read(_recoveryPendingStoreKey) != null;

  /// Loads the data key into memory. Pass [prefetched] when the caller
  /// already has the bytes (e.g. [unlockWithPin] reads it alongside the PIN
  /// verifier) so it is not read from secure storage a second time.
  Future<void> _loadActiveDataKey([Uint8List? prefetched]) async {
    final bytes = prefetched ?? await keyStore.read(_dataKeyStoreKey);
    if (bytes == null || bytes.length != 32) {
      throw const SecurityException(
        code: 'missing_data_key',
        userMessage: 'بيانات الحماية غير مكتملة.',
      );
    }
    _activeDataKey = await _cipher.newSecretKeyFromBytes(bytes);
  }

  SecretKey _requireUnlocked() {
    final key = _activeDataKey;
    if (_locked || key == null) {
      throw const SecurityException(
        code: 'app_locked',
        userMessage: 'افتح التطبيق أولاً.',
      );
    }
    return key;
  }

  void _setLockState(AppLockState state) {
    final nextLocked = state == AppLockState.locked;
    if (_locked == nextLocked) {
      return;
    }
    _locked = nextLocked;
    _lockStates.add(state);
  }
}
