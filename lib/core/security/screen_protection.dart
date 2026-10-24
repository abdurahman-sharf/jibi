abstract interface class ScreenProtection {
  Future<void> setEnabled(bool enabled);
}

/// Coordinates an injected platform screen-protection adapter.
final class ScreenProtectionController {
  ScreenProtectionController(this._screenProtection);

  final ScreenProtection _screenProtection;

  Future<void> apply({required bool enabled}) =>
      _screenProtection.setEnabled(enabled);
}
