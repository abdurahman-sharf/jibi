import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../core/backup/backup_schedule.dart';
import '../core/backup/encrypted_local_backup_service.dart';
import '../core/backup/backup_service.dart';
import '../core/database/app_database.dart';
import '../core/diagnostics/phase_trace.dart';
import '../core/database/sqlite_book_repository.dart';
import '../core/database/sqlite_jibi_repository.dart';
import '../core/errors/app_exception.dart';
import '../core/models/app_settings.dart';
import '../core/models/currency.dart';
import '../core/security/app_lock.dart';
import '../core/security/aes_gcm_security_service.dart';
import '../core/security/platform_adapters.dart';
import '../core/security/screen_protection.dart';
import '../core/security/security_service.dart';
import '../core/storage/file_sharing.dart';
import '../core/storage/profile_image_shrinker.dart';
import '../core/storage/secure_file_storage.dart';
import '../core/storage/text_sharing.dart';
import '../features/book/book_services.dart';
import '../features/book/controllers/book_attachments_controller.dart';
import '../features/book/domain/book_preferences.dart';
import '../features/book/domain/book_labels.dart';
import '../features/book/reports/report_builder.dart';
import '../features/book/reports/report_exporter.dart';
import '../features/book/reports/report_models.dart' show ReportBranding;
import '../features/book/reports/report_pdf.dart' show ReportFonts;
import '../features/profile/user_profile_controller.dart';
import '../shared/formatting/money_format.dart';
import '../features/credentials/credentials.dart';
import '../features/currencies/currencies.dart';
import '../features/documents/documents_controller.dart';
import '../features/home/domain/backup_status.dart';
import '../features/reminders/domain/notification_scheduler.dart';
import '../features/reminders/reminder_coordinator.dart';
import '../features/home/domain/recent_activity.dart';
import '../features/home/presentation/dashboard_summary.dart';

/// Production dependency composition. UI receives controllers only, while this
/// layer owns device paths, platform adapters, SQLite, and encrypted files.
final class JibiApplication {
  JibiApplication._({
    required this.database,
    required this.repository,
    required this.bookRepository,
    required this.book,
    required this.security,
    required this.fileStorage,
    required this.credentials,
    required this.documents,
    required this.currencyRegistry,
    required this.currencies,
    required this.profile,
    required this.backupService,
    required this.backupDirectory,
    required this.notificationScheduler,
    required MutableAppLockPolicy lockPolicy,
    required ScreenProtectionController screenProtection,
    required AppSettings settings,
  }) : _lockPolicy = lockPolicy,
       _screenProtection = screenProtection,
       _settings = settings,
       appLock = AppLockController(
         securityService: security,
         policy: lockPolicy,
       );

  static const _idGenerator = Uuid();

  final AppDatabase database;
  final SqliteJibiRepository repository;

  /// The accounts book (مدونة الحسابات): categories, accounts, transactions.
  final SqliteBookRepository bookRepository;
  final BookServices book;
  final SecurityService security;
  final SecureFileStorage fileStorage;
  final CredentialVaultController credentials;
  final DocumentsController documents;

  /// Shared, mutable currency source of truth used by every controller and
  /// screen. Currency CRUD flows through [currencies] and this instance.
  final CurrencyRegistry currencyRegistry;
  final CurrenciesController currencies;

  /// The issuer of the reports (names, contact, logo, signature, stamp).
  final UserProfileController profile;
  final BackupService backupService;
  final Directory backupDirectory;
  final NotificationScheduler notificationScheduler;
  final AppLockController appLock;
  final MutableAppLockPolicy _lockPolicy;
  final ScreenProtectionController _screenProtection;
  late final ReminderCoordinator reminders = ReminderCoordinator(
    scheduler: notificationScheduler,
    readSettings: () => _settings,
    readBackupStatus: readBackupStatus,
  );
  AppSettings _settings;
  late final ValueNotifier<AppSettings> _settingsNotifier = ValueNotifier(
    _settings,
  );
  int _externalActivityDepth = 0;

  /// Installed by the app shell (it owns the navigator) to ask for the PIN
  /// when biometric re-authentication is unavailable or declined.
  Future<bool> Function()? pinReauthenticator;

  Future<bool> _requestPinReauthentication() async =>
      await pinReauthenticator?.call() ?? false;

  AppSettings get settings => _settings;

  /// Fires after every successful [saveSettings] with the new settings.
  ValueListenable<AppSettings> get settingsListenable => _settingsNotifier;
  bool get isExternalActivityInProgress => _externalActivityDepth > 0;

  /// Keeps an app-initiated Android activity (account chooser or document
  /// picker) from being mistaken for the user leaving Jibi. The counter makes
  /// nested platform flows safe and is always restored when the call ends.
  ///
  /// Share sheets return from the platform call before the other activity
  /// pauses Jibi. With [holdUntilResumed] the guard is kept until the shell
  /// reports the next foreground event through
  /// [releaseHeldExternalActivities] (or [_heldActivityTimeout] passes), so
  /// that late `paused` event cannot lock the app.
  Future<T> runExternalActivity<T>(
    Future<T> Function() action, {
    bool holdUntilResumed = false,
  }) async {
    _externalActivityDepth += 1;
    var hold = false;
    try {
      final result = await action();
      hold = holdUntilResumed;
      return result;
    } finally {
      if (hold) {
        _holdUntilForegrounded();
      } else {
        _externalActivityDepth -= 1;
      }
    }
  }

  static const _heldActivityTimeout = Duration(minutes: 10);
  final List<void Function()> _heldReleases = [];

  void _holdUntilForegrounded() {
    var released = false;
    late Timer failsafe;
    void release() {
      if (released) return;
      released = true;
      failsafe.cancel();
      _heldReleases.remove(release);
      _externalActivityDepth -= 1;
    }

    failsafe = Timer(_heldActivityTimeout, release);
    _heldReleases.add(release);
  }

  /// Called by the app shell once it has handled the `resumed` event that
  /// follows a trip to another activity.
  void releaseHeldExternalActivities() {
    for (final release in List.of(_heldReleases)) {
      release();
    }
  }

  /// Whether a biometric unlock can work right now. False for security
  /// services that expose no biometric capability.
  Future<bool> biometricsAvailable() async {
    final service = security;
    if (service is! BiometricCapability) {
      return false;
    }
    try {
      return await (service as BiometricCapability).canUseBiometrics();
    } on Object {
      return false;
    }
  }

  /// The fingerprint step of the gate in front of exporting and sharing.
  ///
  /// True: a biometric confirmed. False: it was tried and did not confirm
  /// (cancelled, wrong finger, locked out). Null: it was not tried because the
  /// user turned biometrics off or none is enrolled. Anything but true means
  /// the caller falls back to the PIN.
  Future<bool?> confirmWithBiometrics() async {
    if (!_settings.biometricsEnabled || !await biometricsAvailable()) {
      return null;
    }
    try {
      // The system prompt must not be mistaken for the user leaving Jibi.
      final result = await runExternalActivity(security.reauthenticate);
      return result.authenticated;
    } on Object {
      return false;
    }
  }

  /// The Arabic fonts embedded in report PDFs.
  static Future<ReportFonts> _loadReportFonts() async {
    Future<Uint8List> load(String asset) async {
      final data = await rootBundle.load(asset);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    }

    return ReportFonts(
      regular: await load('assets/fonts/Tajawal-Regular.ttf'),
      bold: await load('assets/fonts/Tajawal-Bold.ttf'),
    );
  }

  static Future<JibiApplication> create({
    Directory? directory,
    SecurityService? securityService,
    NotificationScheduler? notificationScheduler,
  }) async {
    // Temporary diagnostics for the cold-start performance investigation —
    // see lib/core/diagnostics/phase_trace.dart. This is the ONE-TIME cost of
    // a fresh process (before the lock screen ever appears, well before any
    // PIN is typed); it is reported separately from `unlockWithPin`'s own
    // trace precisely so the two are never confused with one another.
    final trace = PhaseTrace('JibiApplication.create (cold start)');
    final supportDirectory =
        directory ?? await getApplicationSupportDirectory();
    final encryptedFiles = Directory(
      '${supportDirectory.path}${Platform.pathSeparator}encrypted_documents',
    );
    final temporaryFiles = Directory(
      '${supportDirectory.path}${Platform.pathSeparator}temporary_documents',
    );
    final backups = Directory(
      '${supportDirectory.path}${Platform.pathSeparator}backups',
    );
    await backups.create(recursive: true);
    // Safety copies made before a restore live in their own folder so they do
    // not show up in the backup list or affect retention and reminders.
    final rollbacks = Directory(
      '${backups.path}${Platform.pathSeparator}rollback',
    );
    await trace.measure(
      'Rollback backup cleanup',
      () => moveRollbackBackups(from: backups, to: rollbacks),
    );

    final database = AppDatabase(
      path: '${supportDirectory.path}${Platform.pathSeparator}database.sqlite',
    );
    final repository = SqliteJibiRepository(database);
    // Home listens to this repository's change stream (settings,
    // credentials, documents), so a book write also pokes it: the dashboard
    // and recent activity read the book.
    final bookRepository = SqliteBookRepository(
      database,
      onChanged: repository.refresh,
    );
    final security =
        securityService ??
        AesGcmSecurityService(
          keyStore: FlutterSecureKeyStore(),
          biometricAuthenticator: LocalAuthBiometricAuthenticator(),
        );
    final fileStorage = FileSystemSecureFileStorage(
      encryptedDirectory: encryptedFiles,
      temporaryDirectory: temporaryFiles,
      securityService: security,
    );
    // First real access to the database: opens the file (or creates it) and,
    // only on a version bump, runs the pending migrations — both happen here,
    // not on every unlock (see AppDatabase.database's cached-connection
    // getter).
    final settings = await trace.measure(
      'Database open (+ migrations if pending) and settings read',
      () => repository.read(),
    );
    final currencyRows = await trace.measure(
      'Currency list read',
      () => repository.watchCurrencies().first,
    );
    final currencyRegistry = CurrencyRegistry(
      currencyRows.isEmpty
          ? CurrencyRegistry.defaults().currencies
          : currencyRows,
    );
    final lockPolicy = MutableAppLockPolicy(
      _durationFor(settings.autoLockDuration),
    );
    final profile = UserProfileController(
      repository: repository,
      shrinkImage: shrinkProfileImage,
    );
    await trace.measure('Profile load', () => profile.load());
    late final JibiApplication application;
    final constructionWatch = Stopwatch()..start();
    application = JibiApplication._(
      database: database,
      repository: repository,
      bookRepository: bookRepository,
      book: BookServices(
        repository: bookRepository,
        currencies: currencyRegistry,
        defaultCurrencyCode: () => application.settings.defaultCurrencyCode,
        storage: fileStorage,
        attachments: BookAttachmentsController(
          repository: bookRepository,
          storage: fileStorage,
        ),
        // Reports follow the settings (side wording, date format) and the
        // profile (letterhead, signature, stamp) as they are at build time.
        reports: BookReportBuilder(
          repository: bookRepository,
          currencies: currencyRegistry,
          preferences: () => BookPreferences.fromSettings(application.settings),
          branding: () async => ReportBranding.fromProfile(profile.current),
        ),
        // Reports are built in a temporary folder that the startup cleanup
        // also empties (file names start with "jibi-doc-").
        exporter: SharingReportExporter(
          temporaryDirectory: temporaryFiles,
          loadFonts: _loadReportFonts,
          shareFile: const AndroidFileSharing().share,
          shareText: const AndroidTextSharing().share,
          saveFile: const AndroidFileSharing().save,
          printFile: const AndroidFileSharing().printPdf,
          whatsAppPackages: whatsAppPackages,
          labels: () => BookLabels.fromSettings(application.settings),
        ),
      ),
      security: security,
      fileStorage: fileStorage,
      credentials: CredentialVaultController(
        repository: repository,
        securityService: security,
        clipboard: SensitiveClipboardController(
          clipboard: const FlutterClipboardPort(),
        ),
        createId: _idGenerator.v4,
        requestPinReauthentication: () =>
            application._requestPinReauthentication(),
        clipboardClearAfter: () => application.settings.clipboardClearAfter,
      ),
      documents: DocumentsController(
        repository: repository,
        fileStorage: fileStorage,
        securityService: security,
        idGenerator: _idGenerator.v4,
      ),
      currencyRegistry: currencyRegistry,
      currencies: CurrenciesController(
        repository: repository,
        registry: currencyRegistry,
        defaultCurrencyCode: () => application.settings.defaultCurrencyCode,
      ),
      profile: profile,
      backupService: EncryptedLocalBackupService(
        database: database,
        securityService: security,
        encryptedFilesDirectory: encryptedFiles,
        rollbackDirectory: rollbacks,
      ),
      backupDirectory: backups,
      notificationScheduler:
          notificationScheduler ?? const NoopNotificationScheduler(),
      lockPolicy: lockPolicy,
      screenProtection: ScreenProtectionController(FlutterScreenProtection()),
      settings: settings,
    );
    trace.mark('Services construction (BookServices, controllers)', constructionWatch.elapsedMilliseconds);
    await trace.measure(
      'Cleanup temporary files',
      () => application.fileStorage.cleanupTemporaryFiles(),
    );
    unawaited(application.reminders.sync());
    try {
      await trace.measure(
        'Screen protection (platform channel)',
        () => application._screenProtection.apply(
          enabled: settings.screenshotProtectionEnabled,
        ),
      );
    } on SecurityException catch (error) {
      // A missing or unavailable platform channel must not prevent the user
      // from reaching onboarding. The sensitive-screen setting remains
      // enabled and can be retried from Settings.
      debugPrint('Jibi screen protection unavailable: ${error.code}');
    }
    trace.report();
    return application;
  }

  Future<void> saveSettings(AppSettings settings) async {
    final scheduleChanged = settings.backupSchedule != _settings.backupSchedule;
    await repository.save(settings);
    _settings = settings;
    _lockPolicy.timeout = _durationFor(settings.autoLockDuration);
    await _screenProtection.apply(
      enabled: settings.screenshotProtectionEnabled,
    );
    _settingsNotifier.value = settings;
    if (scheduleChanged) {
      unawaited(reminders.sync());
    }
  }

  Stream<DashboardSummary> watchDashboard() async* {
    yield await _readDashboard();
    await for (final _ in repository.changes) {
      yield await _readDashboard();
    }
  }

  Stream<List<RecentActivityItem>> watchRecentActivity({int limit = 5}) async* {
    yield await readRecentActivity(limit: limit);
    await for (final _ in repository.changes) {
      yield await readRecentActivity(limit: limit);
    }
  }

  Future<List<RecentActivityItem>> readRecentActivity({int limit = 5}) async {
    final items = <RecentActivityItem>[];
    for (final transaction in await bookRepository.recentTransactions(
      limit: limit,
    )) {
      final account = await bookRepository.account(transaction.accountId);
      // The currency belongs to the transaction, not to the account.
      final fractionDigits = currencyRegistry
          .byCode(transaction.currencyCode)
          .fractionDigits;
      items.add(
        RecentActivityItem(
          id: 'tx:${transaction.id}',
          kind: RecentActivityKind.transaction,
          title: account?.name ?? 'حساب',
          subtitle:
              '${BookLabels.fromSettings(_settings).entry(transaction.type)} '
              '${formatMinorGrouped(transaction.amountMinor, fractionDigits)} '
              '${transaction.currencyCode}'.trim(),
          // Built from the local date and time, not from UTC.
          occurredAt: transaction.occurredAt,
        ),
      );
    }
    final credentialList = await credentials.watch().first;
    for (final credential in credentialList) {
      items.add(
        RecentActivityItem(
          id: 'credential:${credential.id}',
          kind: RecentActivityKind.credential,
          title: credential.title,
          subtitle: 'كلمة مرور محفوظة',
          occurredAt: credential.updatedAt,
        ),
      );
    }
    final documentList = await documents.watchDocuments().first;
    for (final document in documentList) {
      items.add(
        RecentActivityItem(
          id: 'document:${document.id}',
          kind: RecentActivityKind.document,
          title: document.title,
          subtitle: 'مستند محفوظ',
          occurredAt: document.updatedAt,
        ),
      );
    }
    return mergeRecentActivities(items, limit: limit);
  }

  /// Creates an encrypted local backup protected by [pin], prunes old ones per
  /// the retention setting, and re-plans the backup reminders. The caller must
  /// have verified [pin] (see [SecurityService.verifyPin]).
  Future<CreatedBackup> createBackup({required String pin}) async {
    final now = DateTime.now().toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    final file = File(
      '${backupDirectory.path}${Platform.pathSeparator}'
      'jibi_backup_${now.year}${two(now.month)}${two(now.day)}_${now.millisecondsSinceEpoch}.jibi',
    );
    final descriptor = await backupService.createLocalBackup(
      destination: file,
      recoveryPassword: pin,
    );
    await pruneOldBackups(
      directory: backupDirectory,
      retentionCount: _settings.backupRetentionCount,
    );
    unawaited(reminders.sync());
    return CreatedBackup(
      file: file,
      descriptor: descriptor,
      shareName: backupShareName(now.toLocal()),
    );
  }

  /// Creates a backup right after a PIN unlock when one is due and the user
  /// left "automatic backup" on. Returns null when nothing was needed.
  /// [pin] must be the PIN that just unlocked the app; it is not kept.
  Future<CreatedBackup?> runScheduledBackupIfDue(String pin) async {
    if (!_settings.autoBackupOnUnlock) {
      return null;
    }
    final status = await readBackupStatus();
    if (!status.due) {
      return null;
    }
    return createBackup(pin: pin);
  }

  /// Local backup state for the dashboard banner. Safety copies made before a
  /// restore are ignored (see [isListedBackup]).
  Future<BackupStatus> readBackupStatus() async {
    final last = await lastLocalBackupTime(backupDirectory);
    return BackupStatus(
      lastBackupAt: last,
      due: shouldRunBackup(
        schedule: _settings.backupSchedule,
        lastRun: last,
        now: DateTime.now().toUtc(),
      ),
    );
  }

  Future<void> refreshAfterRestore() async {
    unawaited(reminders.sync());
    currencyRegistry.replaceAll(await repository.watchCurrencies().first);
    await profile.reload();
    var restoredSettings = await repository.read();
    // A backup from another phone may carry biometrics=true; never keep it on
    // when this device has nothing enrolled.
    if (restoredSettings.biometricsEnabled && !await biometricsAvailable()) {
      restoredSettings = restoredSettings.copyWith(biometricsEnabled: false);
    }
    await saveSettings(restoredSettings);
    repository.refresh();
    bookRepository.refresh();
  }

  Future<void> dispose() async {
    _settingsNotifier.dispose();
    profile.dispose();
    await bookRepository.dispose();
    await repository.dispose();
    await database.close();
  }

  static Duration _durationFor(AutoLockDuration duration) => switch (duration) {
    AutoLockDuration.immediate => Duration.zero,
    AutoLockDuration.oneMinute => const Duration(minutes: 1),
    AutoLockDuration.fiveMinutes => const Duration(minutes: 5),
    AutoLockDuration.fifteenMinutes => const Duration(minutes: 15),
  };

  bool _dashboardTraceLogged = false;

  Future<DashboardSummary> _readDashboard() async {
    // What people owe the user (debit balances) and what the user owes them
    // (credit balances), per currency, over the visible accounts of the book.
    //
    // Note for the startup-performance investigation: Home is built (and this
    // stream subscribed to) the moment the app's widget tree exists, `Offstage`
    // behind the lock screen — well before the PIN is typed, let alone
    // verified. So the FIRST reading below is informative, but its cost is NOT
    // part of the PIN → Home wall-clock gap; it already ran in the background
    // while the user was looking at the lock screen. Only logged once (not on
    // every later refresh after a write) to avoid log spam during normal use.
    final logThisRead = !_dashboardTraceLogged;
    _dashboardTraceLogged = true;
    final trace = logThisRead
        ? PhaseTrace('Dashboard initial data (loads in the background, not after unlock)')
        : null;
    final position = trace == null
        ? await bookRepository.netPosition()
        : await trace.measure('netPosition()', bookRepository.netPosition);
    final walletTotals = trace == null
        ? await bookRepository.walletTotalsByCurrency()
        : await trace.measure(
            'walletTotalsByCurrency()',
            bookRepository.walletTotalsByCurrency,
          );
    trace?.report();
    return DashboardSummary.of(position: position, walletTotals: walletTotals);
  }
}

/// Mutable only within the application composition when settings are changed.
final class MutableAppLockPolicy implements AppLockPolicy {
  MutableAppLockPolicy(this.timeout);

  Duration timeout;

  @override
  bool shouldLock(Duration backgroundDuration) =>
      (backgroundDuration.isNegative ? Duration.zero : backgroundDuration) >=
      timeout;
}
