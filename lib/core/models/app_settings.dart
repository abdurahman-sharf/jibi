import '../errors/app_exception.dart';
import 'book.dart';
import 'model_validation.dart';

enum AppThemePreference { system, light, dark }

enum AutoLockDuration { immediate, oneMinute, fiveMinutes, fifteenMinutes }

enum BackupSchedule { off, daily, weekly, monthly }

/// How a transaction date (stored as `YYYY-MM-DD`) is written on screen and in
/// reports. The stored value never changes.
enum DateDisplayFormat {
  /// `2026-09-20`
  yearMonthDay,

  /// `20/09/2026`
  dayMonthYearSlash,

  /// `20-09-2026`
  dayMonthYearDash,
}

/// Longest custom wording for a debit or credit side.
const int maxSideLabelLength = 24;

/// Trims a custom side wording; blank means "use the standard word".
String? normalizeSideLabel(String? value) {
  final trimmed = value?.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  if (trimmed.length > maxSideLabelLength) {
    throw const ValidationException(
      code: 'side_label_too_long',
      userMessage: 'التسمية يجب ألا تتجاوز 24 حرفاً.',
    );
  }
  return trimmed;
}

/// A custom wording, or null when it is blank or just the standard word.
String? _customSideLabel(String? value, String standard) {
  final label = normalizeSideLabel(value);
  return label == standard ? null : label;
}

final class AppSettings {
  AppSettings({
    required String defaultCurrencyCode,
    this.localeCode = 'ar',
    this.themePreference = AppThemePreference.system,
    this.autoLockDuration = AutoLockDuration.immediate,
    this.biometricsEnabled = false,
    this.screenshotProtectionEnabled = true,
    this.clipboardClearAfter = const Duration(seconds: 30),
    this.backupSchedule = BackupSchedule.off,
    this.autoBackupOnUnlock = true,
    this.backupRetentionCount = 5,
    this.dateFormat = DateDisplayFormat.yearMonthDay,
    this.showTransactionTime = true,
    this.hideBalances = false,
    this.newestFirst = true,
    this.confirmBeforeDelete = true,
    this.defaultEntryType = EntryType.debit,
    String? debitLabel,
    String? creditLabel,
    this.showCoachMarks = true,
    Set<String> seenTours = const <String>{},
  }) : seenTours = Set<String>.unmodifiable(seenTours),
       defaultCurrencyCode = requireText(
         defaultCurrencyCode,
         'default_currency_code',
       ).toUpperCase(),
       debitLabel = _customSideLabel(debitLabel, 'مدين'),
       creditLabel = _customSideLabel(creditLabel, 'دائن') {
    if (clipboardClearAfter.isNegative || backupRetentionCount < 1) {
      throw ArgumentError('Invalid settings duration or retention count.');
    }
    final debit = this.debitLabel;
    final credit = this.creditLabel;
    if (debit != null && debit == (credit ?? 'دائن') ||
        credit != null && credit == (debit ?? 'مدين')) {
      throw const ValidationException(
        code: 'side_labels_equal',
        userMessage: 'يجب أن تختلف تسمية المدين عن تسمية الدائن.',
      );
    }
  }

  final String defaultCurrencyCode;
  final String localeCode;
  final AppThemePreference themePreference;
  final AutoLockDuration autoLockDuration;
  final bool biometricsEnabled;
  final bool screenshotProtectionEnabled;
  final Duration clipboardClearAfter;
  final BackupSchedule backupSchedule;

  /// Creates a due backup right after the PIN unlocks the app. Has no effect
  /// while [backupSchedule] is off, and cannot run after a biometric unlock
  /// because the PIN (the backup password) is never stored.
  final bool autoBackupOnUnlock;
  final int backupRetentionCount;

  /// How dates are written (screens and reports).
  final DateDisplayFormat dateFormat;

  /// Whether the transaction table shows the time under the date.
  final bool showTransactionTime;

  /// Hides balances and totals on the accounts screens (privacy).
  final bool hideBalances;

  /// Default order of an account's transactions.
  final bool newestFirst;

  /// Whether deleting a transaction asks first. When off the deletion happens
  /// at once and stays undoable from the message that follows.
  final bool confirmBeforeDelete;

  /// The side pre-selected in the new-transaction form.
  final EntryType defaultEntryType;

  /// Custom wording of the two sides, or null for the standard "مدين"/"دائن".
  /// Presentation only: the stored type stays DEBIT/CREDIT.
  final String? debitLabel;
  final String? creditLabel;

  /// Whether the animated hints over the buttons (التلميحات المرئية) appear.
  final bool showCoachMarks;

  /// Ids of the hint tours already shown, so each runs once.
  final Set<String> seenTours;

  /// The same settings with [tour] marked as shown.
  AppSettings withSeenTour(String tour) =>
      copyWith(seenTours: {...seenTours, tour});

  AppSettings copyWith({
    String? defaultCurrencyCode,
    String? localeCode,
    AppThemePreference? themePreference,
    AutoLockDuration? autoLockDuration,
    bool? biometricsEnabled,
    bool? screenshotProtectionEnabled,
    Duration? clipboardClearAfter,
    BackupSchedule? backupSchedule,
    bool? autoBackupOnUnlock,
    int? backupRetentionCount,
    DateDisplayFormat? dateFormat,
    bool? showTransactionTime,
    bool? hideBalances,
    bool? newestFirst,
    bool? confirmBeforeDelete,
    EntryType? defaultEntryType,
    bool? showCoachMarks,
    Set<String>? seenTours,
  }) => AppSettings(
    defaultCurrencyCode: defaultCurrencyCode ?? this.defaultCurrencyCode,
    localeCode: localeCode ?? this.localeCode,
    themePreference: themePreference ?? this.themePreference,
    autoLockDuration: autoLockDuration ?? this.autoLockDuration,
    biometricsEnabled: biometricsEnabled ?? this.biometricsEnabled,
    screenshotProtectionEnabled:
        screenshotProtectionEnabled ?? this.screenshotProtectionEnabled,
    clipboardClearAfter: clipboardClearAfter ?? this.clipboardClearAfter,
    backupSchedule: backupSchedule ?? this.backupSchedule,
    autoBackupOnUnlock: autoBackupOnUnlock ?? this.autoBackupOnUnlock,
    backupRetentionCount: backupRetentionCount ?? this.backupRetentionCount,
    dateFormat: dateFormat ?? this.dateFormat,
    showTransactionTime: showTransactionTime ?? this.showTransactionTime,
    hideBalances: hideBalances ?? this.hideBalances,
    newestFirst: newestFirst ?? this.newestFirst,
    confirmBeforeDelete: confirmBeforeDelete ?? this.confirmBeforeDelete,
    defaultEntryType: defaultEntryType ?? this.defaultEntryType,
    debitLabel: debitLabel,
    creditLabel: creditLabel,
    showCoachMarks: showCoachMarks ?? this.showCoachMarks,
    seenTours: seenTours ?? this.seenTours,
  );

  /// Replaces the two custom side wordings (null or blank = standard).
  /// [copyWith] cannot clear a value, so this is separate.
  AppSettings withSideLabels({String? debit, String? credit}) => AppSettings(
    defaultCurrencyCode: defaultCurrencyCode,
    localeCode: localeCode,
    themePreference: themePreference,
    autoLockDuration: autoLockDuration,
    biometricsEnabled: biometricsEnabled,
    screenshotProtectionEnabled: screenshotProtectionEnabled,
    clipboardClearAfter: clipboardClearAfter,
    backupSchedule: backupSchedule,
    autoBackupOnUnlock: autoBackupOnUnlock,
    backupRetentionCount: backupRetentionCount,
    dateFormat: dateFormat,
    showTransactionTime: showTransactionTime,
    hideBalances: hideBalances,
    newestFirst: newestFirst,
    confirmBeforeDelete: confirmBeforeDelete,
    defaultEntryType: defaultEntryType,
    debitLabel: debit,
    creditLabel: credit,
    showCoachMarks: showCoachMarks,
    seenTours: seenTours,
  );
}
