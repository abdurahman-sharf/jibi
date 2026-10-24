import 'package:jibi/core/security/security.dart';

/// A phone whose own lock (fingerprint or screen lock) can or cannot confirm
/// the person, for the forgotten-PIN tests. Biometric unlock itself is off, so
/// only the reset path can use it.
class FakeDeviceIdentity implements BiometricAuthenticator, DeviceIdentityVerifier {
  FakeDeviceIdentity({this.available = true, this.confirms = true});

  /// Whether the phone has a fingerprint or a screen lock at all.
  bool available;

  /// Whether the person passes the system prompt.
  bool confirms;

  /// How many times the system prompt was shown.
  int prompts = 0;

  @override
  Future<bool> authenticate({required String reason}) async => false;

  @override
  Future<bool> canAuthenticate() async => false;

  @override
  Future<bool> canVerifyIdentity() async => available;

  @override
  Future<bool> verifyIdentity({required String reason}) async {
    prompts += 1;
    return confirms;
  }
}
