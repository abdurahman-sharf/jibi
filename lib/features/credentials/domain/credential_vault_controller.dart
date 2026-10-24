import '../../../core/models/credential.dart';
import '../../../core/repositories/repositories.dart';
import '../../../core/security/security_service.dart';
import 'clipboard.dart';

/// Plaintext received only at the feature boundary and encrypted before it
/// reaches [CredentialsRepository].
final class CredentialInput {
  const CredentialInput({
    required this.title,
    required this.username,
    required this.email,
    required this.password,
    required this.notes,
    this.url,
    this.categoryId,
    this.isFavorite = false,
  });

  final String title;
  final String username;
  final String email;
  final String password;
  final String notes;
  final String? url;
  final String? categoryId;
  final bool isFavorite;

  @override
  String toString() => 'CredentialInput([redacted])';
}

/// Decrypted credential content. Instances are deliberately short-lived and
/// must not be persisted, logged, or retained by presentation state.
final class CredentialDetails {
  const CredentialDetails({
    required this.credential,
    required this.username,
    required this.email,
    required this.password,
    required this.notes,
  });

  final Credential credential;
  final String username;
  final String email;
  final String password;
  final String notes;

  @override
  String toString() => 'CredentialDetails([redacted])';
}

/// Repository-backed vault operations. All sensitive fields are passed through
/// [SecurityService] before saving and only decrypted after the service permits
/// access.
final class CredentialVaultController {
  CredentialVaultController({
    required this.repository,
    required this.securityService,
    required this.clipboard,
    required this.createId,
    this.requestPinReauthentication,
    Duration Function()? clipboardClearAfter,
    DateTime Function()? clock,
  }) : _clipboardClearAfter =
           clipboardClearAfter ?? (() => const Duration(seconds: 30)),
       _clock = clock ?? DateTime.now;

  final CredentialsRepository repository;
  final SecurityService securityService;
  final SensitiveClipboardController clipboard;
  final String Function() createId;

  /// Fallback used when biometric re-authentication is unavailable or
  /// declined. Returns true only after the user proved knowledge of the PIN.
  /// It needs UI, so the app shell provides it; null disables the fallback.
  final Future<bool> Function()? requestPinReauthentication;
  final DateTime Function() _clock;
  final Duration Function() _clipboardClearAfter;

  /// How long a copied password may stay on the clipboard (from Settings).
  Duration get clipboardClearAfter => _clipboardClearAfter();

  Stream<List<Credential>> watch({
    String? query,
    String? categoryId,
    bool favoritesOnly = false,
  }) => repository.watchCredentials(
    query: query,
    categoryId: categoryId,
    favoritesOnly: favoritesOnly,
  );

  Future<Credential> create(CredentialInput input) async {
    final now = _clock();
    final credential = await _encryptInput(
      input: input,
      id: createId(),
      createdAt: now,
      updatedAt: now,
    );
    await repository.saveCredential(credential);
    return credential;
  }

  Future<Credential> update({
    required Credential existing,
    required CredentialInput input,
  }) async {
    final now = _clock();
    final credential = await _encryptInput(
      input: input,
      id: existing.id,
      createdAt: existing.createdAt,
      updatedAt: now.isBefore(existing.createdAt) ? existing.createdAt : now,
    );
    await repository.saveCredential(credential);
    return credential;
  }

  Future<CredentialDetails?> read(String id) async {
    final credential = await repository.findCredential(id);
    if (credential == null) {
      return null;
    }
    if (!await _reauthenticated()) {
      return null;
    }
    return CredentialDetails(
      credential: credential,
      username: await securityService.decryptText(credential.usernameEncrypted),
      email: await securityService.decryptText(credential.emailEncrypted),
      password: await securityService.decryptText(credential.passwordEncrypted),
      notes: await securityService.decryptText(credential.notesEncrypted),
    );
  }

  /// Returns false when re-authentication is declined so the caller never
  /// reports a copy that did not happen.
  Future<bool> copyPassword(
    Credential credential, {
    Duration? clearAfter,
  }) async {
    if (!await _reauthenticated()) {
      return false;
    }
    final password = await securityService.decryptText(
      credential.passwordEncrypted,
    );
    await clipboard.copySecret(password, clearAfter: clearAfter ?? clipboardClearAfter);
    return true;
  }

  /// Copies the username after the same re-authentication as the password.
  Future<bool> copyUsername(Credential credential) async {
    if (!await _reauthenticated()) {
      return false;
    }
    final username = await securityService.decryptText(
      credential.usernameEncrypted,
    );
    await clipboard.copySecret(username, clearAfter: clipboardClearAfter);
    return true;
  }

  Future<void> delete(String id) => repository.deleteCredential(id);

  Future<bool> _reauthenticated() async {
    final biometric = await securityService.reauthenticate();
    if (biometric.authenticated) {
      return true;
    }
    final fallback = requestPinReauthentication;
    return fallback != null && await fallback();
  }

  Future<Credential> _encryptInput({
    required CredentialInput input,
    required String id,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) async {
    final encrypted = await Future.wait([
      securityService.encryptText(input.username),
      securityService.encryptText(input.email),
      securityService.encryptText(input.password),
      securityService.encryptText(input.notes),
    ]);
    return Credential(
      id: id,
      title: input.title,
      usernameEncrypted: encrypted[0],
      emailEncrypted: encrypted[1],
      passwordEncrypted: encrypted[2],
      notesEncrypted: encrypted[3],
      url: input.url,
      categoryId: input.categoryId,
      isFavorite: input.isFavorite,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}
