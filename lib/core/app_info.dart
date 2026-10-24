/// The one place the app version is written down. `test/core/app_info_test.dart`
/// checks it against `pubspec.yaml`, so the two cannot drift apart.
abstract final class AppInfo {
  static const String version = '1.18.0';
  static const int buildNumber = 25;

  /// Arabic display form used in Settings, e.g. `1.10.0 (بناء 16)`.
  static const String versionLabel = '$version (بناء $buildNumber)';

  static String get display => versionLabel;
}
