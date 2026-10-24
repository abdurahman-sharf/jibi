import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../core/errors/app_exception.dart';
import '../core/backup/backup_service.dart';
import '../core/backup/backup_file_transfer.dart';
import '../core/diagnostics/phase_trace.dart';
import '../core/models/app_settings.dart';
import '../core/security/app_lock.dart';
import '../core/security/pin_attempt_limiter.dart';
import '../core/security/security_primitives.dart';
import '../core/security/security_service.dart';
import '../features/book/domain/book_labels.dart';
import '../features/book/domain/book_preferences.dart';
import '../features/home/domain/recent_activity.dart';
import '../features/reminders/domain/reminder_planner.dart';
import '../features/home/presentation/home_dashboard.dart';
import '../shared/theme/jibi_theme.dart';
import '../shared/widgets/external_activity_scope.dart';
import '../shared/widgets/jibi_app_icon.dart';
import '../shared/widgets/jibi_design.dart';
import '../shared/widgets/jibi_feedback.dart';
import '../shared/widgets/jibi_onboarding.dart';
import '../shared/widgets/pin_field.dart';
import '../shared/widgets/pin_prompt.dart';
import '../shared/widgets/coach_marks.dart';
import 'book/book_categories_page.dart';
import 'coach_tours.dart';
import 'book/book_preferences_scope.dart';
import 'book/book_export_scope.dart';
import 'book/book_forms.dart';
import 'book/book_navigation.dart';
import 'book/book_transaction_form.dart';
import 'book/reports/book_reports_hub_page.dart';
import 'settings/backup_settings_page.dart';
import 'settings/settings_hub_page.dart';
import 'jibi_app_shell.dart';
import 'jibi_application.dart';
import 'jibi_feature_pages.dart';
import 'wallets/wallet_detail_page.dart';
import 'wallets/wallet_forms.dart';
import 'wallets/wallets_list_page.dart';

enum JibiInitialView { onboarding, shell }

class JibiApp extends StatefulWidget {
  const JibiApp({
    super.key,
    this.application,
    this.initialView = JibiInitialView.onboarding,
    this.onPrimaryAction,
    this.showTips = false,
    this.tipsDelay = const Duration(milliseconds: 700),
  });

  final JibiApplication? application;
  final JibiInitialView initialView;

  /// Whether the animated hints over the buttons (التلميحات المرئية) may
  /// appear. On in the real app; off elsewhere so tests are not covered by an
  /// overlay.
  final bool showTips;

  /// How long a screen is on before its hints appear, so its transition has
  /// finished and the buttons are where the tour will look for them.
  final Duration tipsDelay;

  /// Compatibility callback used by the presentation preview tests.
  final ValueChanged<int>? onPrimaryAction;

  @override
  State<JibiApp> createState() => _JibiAppState();
}

class _JibiAppState extends State<JibiApp> with WidgetsBindingObserver {
  static const BackupFileTransfer _backupFiles = AndroidBackupFileTransfer();
  final _navigatorKey = GlobalKey<NavigatorState>(
    debugLabel: 'jibi-root-navigator',
  );
  final _shellKey = GlobalKey<JibiAppShellState>(debugLabel: 'jibi-shell');
  // Targets of the home hint tour.
  final _tipVault = GlobalKey(debugLabel: 'tip-vault');
  final _tipSearch = GlobalKey(debugLabel: 'tip-search');
  final _tipTheme = GlobalKey(debugLabel: 'tip-theme');
  final _tipSettings = GlobalKey(debugLabel: 'tip-settings');
  final _tipHide = GlobalKey(debugLabel: 'tip-hide');

  late final CoachTourHost? _coachHost =
      widget.showTips && widget.application != null
      ? CoachTourHost(
          delay: widget.tipsDelay,
          isEnabled: () =>
              !_locked &&
              !_showOnboarding &&
              (widget.application?.settings.showCoachMarks ?? false),
          isSeen: (id) =>
              widget.application?.settings.seenTours.contains(id) ?? true,
          markSeen: (id) async {
            final application = widget.application;
            if (application != null) {
              await application.saveSettings(
                application.settings.withSeenTour(id),
              );
            }
          },
        )
      : null;
  late bool _showOnboarding = widget.initialView == JibiInitialView.onboarding;
  late ThemeMode _themeMode = _initialThemeMode();
  late bool _locked = widget.application != null && !_showOnboarding;
  StreamSubscription<AppLockState>? _lockSubscription;
  StreamSubscription<String>? _notificationTaps;
  String? _pendingNotificationPayload;
  bool _privacyHidden = false;

  /// Evaluated once, the first time onboarding is built, so the biometric
  /// switch can default to on when a fingerprint is enrolled.
  late final Future<bool>? _biometricAvailability = _application
      ?.biometricsAvailable();

  JibiApplication? get _application => widget.application;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final application = _application;
    if (application != null) {
      application.pinReauthenticator = _confirmPinForSensitiveAction;
      application.settingsListenable.addListener(_onSettingsChanged);
      _notificationTaps = application.notificationScheduler.taps.listen(
        _onNotificationPayload,
      );
      unawaited(
        application.notificationScheduler.takeLaunchPayload().then((payload) {
          if (payload != null) _onNotificationPayload(payload);
        }),
      );
      _lockSubscription = application.security.lockStates.listen((state) {
        final locked = state == AppLockState.locked;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _locked != locked) {
            setState(() {
              _locked = locked;
              if (!locked) _privacyHidden = false;
            });
            if (!locked) {
              _flushNotificationPayload();
              _scheduleHomeTour();
              // Home was already built (Offstage) underneath the lock screen;
              // this is the frame where it actually becomes visible.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                UnlockTiming.reportHomeVisible();
              });
            }
          }
        });
        WidgetsBinding.instance.scheduleFrame();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _application?.pinReauthenticator = null;
    _application?.settingsListenable.removeListener(_onSettingsChanged);
    _notificationTaps?.cancel();
    _lockSubscription?.cancel();
    super.dispose();
  }

  /// Remembers a tapped notification until the app is unlocked, then routes it.
  void _onNotificationPayload(String payload) {
    _pendingNotificationPayload = payload;
    _flushNotificationPayload();
  }

  void _flushNotificationPayload() {
    final payload = _pendingNotificationPayload;
    if (payload == null || _locked || _showOnboarding || _application == null) {
      return;
    }
    _pendingNotificationPayload = null;
    if (payload == backupReminderPayload) {
      // The navigator may not exist yet on a cold start from a notification.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_openBackupSettings());
      });
    }
  }

  /// Runs a due backup right after a PIN unlock (the PIN is the backup
  /// password and is only available at that moment). Never blocks unlocking.
  Future<void> _autoBackupAfterUnlock(String pin) async {
    final application = _application;
    if (application == null) return;
    try {
      final backup = await application.runScheduledBackupIfDue(pin);
      if (backup == null || !mounted) return;
      setState(() {});
      _showBackupCreated(backup, automatic: true);
    } on Object catch (error) {
      debugPrint('Jibi automatic backup skipped: ${error.runtimeType}');
    }
  }

  /// Home banner action: asks for the PIN, then backs up right away.
  Future<void> _backupNowFromHome() async {
    final application = _application;
    final context = _navigatorKey.currentContext;
    if (application == null || context == null || !context.mounted) return;
    final pin = await _askSecret(
      context,
      title: 'تأكيد رمز PIN',
      label: 'أدخل رمز PIN لتشفير النسخة الاحتياطية',
    );
    if (pin == null || pin.isEmpty || !mounted) return;
    try {
      if (!await application.security.verifyPin(pin)) {
        _showMessage('رمز PIN غير صحيح.');
        return;
      }
      _showMessage('جارٍ إنشاء النسخة الاحتياطية...');
      final backup = await application.createBackup(pin: pin);
      if (!mounted) return;
      setState(() {});
      _showBackupCreated(backup);
    } on AppException catch (error) {
      if (mounted) _showMessage(error.userMessage);
    } on Object {
      if (mounted) _showMessage('تعذر إنشاء النسخة الاحتياطية.');
    }
  }

  void _showBackupCreated(CreatedBackup backup, {bool automatic = false}) {
    final context = _navigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          automatic
              ? 'تم إنشاء نسخة احتياطية تلقائية مشفرة.'
              : 'تم إنشاء النسخة الاحتياطية المشفرة.',
        ),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: 'حفظ في Drive',
          onPressed: () => unawaited(_shareBackupToDrive(backup)),
        ),
      ),
    );
  }

  Future<void> _shareBackupToDrive(CreatedBackup backup) async {
    final application = _application;
    if (application == null) return;
    try {
      final opened = await application.runExternalActivity(
        () => _backupFiles.export(
          backup.file,
          suggestedName: backup.shareName,
          preferGoogleDrive: true,
        ),
        holdUntilResumed: true,
      );
      if (mounted && !opened) {
        _showMessage('تعذر فتح نافذة الحفظ. النسخة محفوظة داخل التطبيق.');
      }
    } on AppException catch (error) {
      if (mounted) _showMessage(error.userMessage);
    } on Object {
      if (mounted) _showMessage('تعذر مشاركة النسخة الاحتياطية.');
    }
  }

  /// Rebuilds the tabs so pages that captured a setting (default currency,
  /// security summary) never keep a stale value after Settings changes it.
  void _onSettingsChanged() {
    // The theme is part of the settings, so it follows a change made on any
    // settings screen (or a restored backup).
    if (mounted) setState(() => _themeMode = _initialThemeMode());
  }

  Future<bool> _confirmPinForSensitiveAction() async {
    final application = _application;
    final context = _navigatorKey.currentContext;
    if (application == null || context == null || !context.mounted) {
      return false;
    }
    final pin = await _askSecret(
      context,
      title: 'تأكيد الهوية',
      label: 'أدخل رمز PIN لعرض البيانات الحساسة',
    );
    if (pin == null || pin.isEmpty) return false;
    try {
      return await application.security.verifyPin(pin);
    } on AppException catch (error) {
      // Too many wrong PINs: say how long to wait instead of a bare refusal.
      _showMessage(error.userMessage);
      return false;
    }
  }

  bool _wasBackgrounded = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final application = _application;
    final returnedFromBackground =
        state == AppLifecycleState.resumed && _wasBackgrounded;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _wasBackgrounded = true;
    } else if (state == AppLifecycleState.resumed) {
      _wasBackgrounded = false;
    }
    if (state == AppLifecycleState.resumed) {
      // Time has passed; make sure the pending reminders still match.
      unawaited(application?.reminders.sync() ?? Future<void>.value());
      // A copied password whose time ran out while the app was in the
      // background (its timer may have been frozen) is cleared now, even if
      // the app locked itself meanwhile.
      unawaited(
        application?.credentials.clipboard.clearIfDue() ?? Future<void>.value(),
      );
    }
    try {
      _handleLifecycle(state);
    } finally {
      // A share sheet keeps the external-activity guard until we are back.
      if (returnedFromBackground) {
        application?.releaseHeldExternalActivities();
      }
    }
  }

  void _handleLifecycle(AppLifecycleState state) {
    final application = _application;
    if (application == null || _showOnboarding || _locked) {
      return;
    }
    if (application.isExternalActivityInProgress) {
      if (state == AppLifecycleState.resumed && _privacyHidden && mounted) {
        setState(() => _privacyHidden = false);
      }
      return;
    }
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(() async {
          await application.appLock.handle(AppLifecycleEvent.foregrounded);
          if (mounted) setState(() => _privacyHidden = false);
        }());
        break;
      case AppLifecycleState.inactive:
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        setState(() => _privacyHidden = true);
        unawaited(application.appLock.handle(AppLifecycleEvent.backgrounded));
        break;
    }
  }

  ThemeMode _initialThemeMode() {
    final preference = widget.application?.settings.themePreference;
    return switch (preference) {
      AppThemePreference.light => ThemeMode.light,
      AppThemePreference.dark => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'جيبي',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      builder: (context, child) {
        final content = Directionality(
          textDirection: TextDirection.rtl,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ExcludeFocus(
                excluding: _locked || _privacyHidden,
                child: Offstage(
                  offstage: _locked || _privacyHidden,
                  child: TickerMode(
                    enabled: !_locked && !_privacyHidden,
                    child: child!,
                  ),
                ),
              ),
              if (_privacyHidden && !_locked)
                const Scaffold(
                  body: Center(child: Icon(Icons.lock_outline, size: 48)),
                ),
              if (_locked && _application != null)
                // The lock screen sits above the Navigator, so it needs its own
                // Overlay for text-selection handles and the paste toolbar.
                Overlay(
                  initialEntries: [
                    OverlayEntry(
                      builder: (_) => _LockScreen(
                        security: _application!.security,
                        biometricsEnabled:
                            _application!.settings.biometricsEnabled,
                        biometricsAvailable: _application!.biometricsAvailable,
                        onPinUnlocked: _autoBackupAfterUnlock,
                        onPinReset: _afterPinReset,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        );
        final application = _application;
        return application == null
            ? content
            : BookPreferencesScope(
                preferences: BookPreferences.fromSettings(application.settings),
                child: BookExportScope(
                  authorize: _authorizeExport,
                  child: ExternalActivityScope(
                    run: application.runExternalActivity,
                    release: application.releaseHeldExternalActivities,
                    child: _withCoachScope(content),
                  ),
                ),
              );
      },
      theme: JibiTheme.light(),
      darkTheme: JibiTheme.dark(),
      themeMode: _themeMode,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: _showOnboarding
            ? JibiOnboardingFlow(
                onPinSubmitted: _application == null ? null : _initializePin,
                biometricAvailability: _application == null
                    ? null
                    : _biometricAvailability,
                onRestoreRequested: _application == null
                    ? null
                    : _restoreDuringOnboarding,
                onCompleted: () {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) {
                      setState(() {
                        _showOnboarding = false;
                        _locked = false;
                      });
                      _flushNotificationPayload();
                      _scheduleHomeTour();
                    }
                  });
                },
              )
            : _buildShell(),
      ),
    );
  }

  Future<String?> _initializePin({
    required String pin,
    required bool biometricsEnabled,
  }) async {
    final application = _application!;
    try {
      // Only keep biometrics on when one is actually enrolled. Settings are
      // saved before the PIN is created so a failure here can be retried
      // without hitting `security_already_initialized`.
      final useBiometrics =
          biometricsEnabled && await application.biometricsAvailable();
      await application.saveSettings(
        application.settings.copyWith(biometricsEnabled: useBiometrics),
      );
      if (await application.security.isRecoverySetupPending) {
        await application.security.completeRecoverySetup(pin: pin);
      } else {
        await application.security.initialize(pin: pin);
      }
      return null;
    } on AppException catch (error) {
      return error.userMessage;
    } on Object {
      return 'تعذر إعداد الحماية. حاول مرة أخرى.';
    }
  }

  Future<bool> _restoreDuringOnboarding() async {
    File? imported;
    final pinController = TextEditingController();
    try {
      imported = await _application!.runExternalActivity(_backupFiles.import);
      if (imported == null || !mounted) return false;
      final pin = await showJibiDialog<String>(
        context: _navigatorKey.currentContext!,
        builder: (dialogContext) => AlertDialog(
          title: const Text('رمز PIN للنسخة'),
          content: PinField(
            controller: pinController,
            label: 'رمز PIN المستخدم عند إنشاء النسخة',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, pinController.text),
              child: const Text('استعادة'),
            ),
          ],
        ),
      );
      if (pin == null || !mounted) return false;
      await _application!.backupService.restoreLocalBackup(
        source: imported,
        recoveryPassword: pin,
      );
      await _application!.refreshAfterRestore();
      if (!mounted) return false;
      _themeMode = _initialThemeMode();
      _showMessage('تمت الاستعادة. أنشئ رمز PIN جديداً لحماية بياناتك.');
      return true;
    } on AppException catch (error) {
      if (mounted) _showMessage(error.userMessage);
      return false;
    } on Object {
      if (mounted) _showMessage('تعذر استعادة النسخة الاحتياطية.');
      return false;
    } finally {
      pinController.dispose();
      if (imported != null && await imported.exists()) {
        await imported.delete();
      }
    }
  }

  /// Runs after the lock screen replaced a forgotten PIN: the app is
  /// unlocking, so say what changed for the backups and back up if one is due.
  Future<void> _afterPinReset(String pin) async {
    if (!mounted) return;
    _showMessage(
      'تم إنشاء رمز PIN جديد وبياناتك كما هي. النسخ الاحتياطية السابقة تُفتح '
      'برمز PIN القديم؛ أنشئ نسخة جديدة.',
      duration: const Duration(seconds: 10),
    );
    await _autoBackupAfterUnlock(pin);
  }

  Widget _buildShell() {
    final application = _application;
    if (application == null) {
      return _previewShell();
    }
    return JibiAppShell(
      key: _shellKey,
      appBar: _appBar(),
      barTabIndices: const [0, 1, 2, 3],
      alternateLayout: JibiShellLayout(
        activeWhen: const {1, 4, 5},
        primaryIndex: 1,
        items: const [
          JibiBarItem.tab(0),
          JibiBarItem.tab(1),
          JibiBarItem.tab(4),
          JibiBarItem.tab(5),
        ],
        quickActions: bookQuickActions(
          book: application.book,
          context: () => _navigatorKey.currentContext!,
        ),
      ),
      quickActions: [
        JibiQuickAction(
          label:
              'عملية ${BookLabels.fromSettings(application.settings).debit} / '
              '${BookLabels.fromSettings(application.settings).credit}',
          description: 'سجّل مبلغًا لك أو عليك في أحد الحسابات',
          icon: Icons.swap_horiz,
          onPressed: _openBookTransaction,
        ),
        JibiQuickAction(
          label: 'حساب جديد',
          description: 'أضف حسابًا داخل أحد التصنيفات',
          icon: Icons.person_add_alt_1_outlined,
          onPressed: _openBookAccountForm,
        ),
        JibiQuickAction(
          label: 'كلمة مرور',
          description: 'احفظ بيانات دخول مشفرة',
          icon: Icons.key_outlined,
          onPressed: _openCredentialForm,
        ),
        JibiQuickAction(
          label: 'مستند',
          description: 'أضف مستندًا مع ملفاته',
          icon: Icons.note_add_outlined,
          onPressed: _openDocumentForm,
        ),
      ],
      tabs: [
        JibiShellTab(
          label: 'الرئيسية',
          icon: Icons.home_outlined,
          selectedIcon: Icons.home,
          child: HomeDashboard(
            hideToggleKey: _tipHide,
            labels: BookLabels.fromSettings(application.settings),
            hideBalances: application.settings.hideBalances,
            onAddTransaction: _openBookTransaction,
            onAddAccount: _openBookAccountForm,
            onAddPassword: _openCredentialForm,
            onAddDocument: _openDocumentForm,
            onOpenSettings: _openSettings,
            summary: application.watchDashboard(),
            currencies: application.currencyRegistry,
            recentActivity: application.watchRecentActivity(limit: 20),
            backupStatus: application.readBackupStatus(),
            onBackupNow: _backupNowFromHome,
            onOpenActivity: _openActivity,
            walletSummaries: application.book.wallets.watchSummaries(
              includeArchived: false,
            ),
            walletTotals: application.book.wallets.watchTotalsByCurrency(),
            onOpenWallet: _openWallet,
            onOpenWallets: _openWalletsList,
            onAddWallet: _openWalletForm,
            defaultCurrencyCode: application.settings.defaultCurrencyCode,
          ),
        ),
        JibiShellTab(
          label: 'الحسابات',
          icon: Icons.category_outlined,
          selectedIcon: Icons.category,
          child: BookCategoriesPage(book: application.book),
        ),
        JibiShellTab(
          label: 'كلمات المرور',
          icon: Icons.key_outlined,
          selectedIcon: Icons.key,
          child: CredentialsPage(
            controller: application.credentials,
            documents: application.documents,
            settings: application.settings,
          ),
        ),
        JibiShellTab(
          label: 'المستندات',
          icon: Icons.folder_outlined,
          selectedIcon: Icons.folder,
          child: DocumentsPage(
            controller: application.documents,
            credentials: application.credentials,
            settings: application.settings,
          ),
        ),
        // Only shown by the accounts bar; built the first time it is opened.
        JibiShellTab(
          label: 'التقارير',
          icon: Icons.bar_chart_outlined,
          selectedIcon: Icons.bar_chart,
          lazy: true,
          child: BookReportsHubPage(book: application.book),
        ),
        // Also only in the accounts bar. Built on first visit; it reads the
        // settings through listeners, so it never shows stale values.
        JibiShellTab(
          label: 'الإعدادات',
          icon: Icons.settings_outlined,
          selectedIcon: Icons.settings,
          lazy: true,
          child: SettingsHubPage(application: application),
        ),
      ],
    );
  }

  Widget _withCoachScope(Widget child) {
    final host = _coachHost;
    return host == null ? child : CoachScope(host: host, child: child);
  }

  /// The hint tour of the home screen (once, right after the first unlock).
  void _scheduleHomeTour() {
    final host = _coachHost;
    if (host == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _navigatorKey.currentContext;
      if (!mounted || context == null) return;
      unawaited(
        host.startOnce(
          context,
          CoachTourIds.home,
          _homeTourSteps,
          // Only while the home tab is the one in front.
          stillApplicable: () => _shellKey.currentState?.selectedIndex == 0,
        ),
      );
    });
  }

  List<CoachStep> _homeTourSteps() {
    final shell = _shellKey.currentState;
    return [
      CoachStep(
        target: _tipSearch,
        title: 'البحث الشامل',
        message: 'ابحث في الحسابات وكلمات المرور والمستندات من مكان واحد.',
      ),
      CoachStep(
        target: _tipTheme,
        title: 'المظهر',
        message: 'بدّل بين الفاتح والداكن، أو دع الهاتف يختار.',
      ),
      CoachStep(
        target: _tipSettings,
        title: 'الإعدادات',
        message:
            'بيانات المستخدم والتصنيفات والعملات والنسخ الاحتياطي والأمان.',
      ),
      CoachStep(
        target: _tipVault,
        title: 'الخزنة',
        message: 'اختصار إلى كلمات المرور المشفرة.',
      ),
      CoachStep(
        target: _tipHide,
        title: 'إخفاء المبالغ',
        message: 'اضغط لإخفاء المبالغ أو إظهارها عندما ينظر أحد إلى شاشتك.',
      ),
      if (shell != null) ...[
        CoachStep(
          target: shell.fabKey,
          title: 'زر الإضافة',
          message:
              'يفتح ورقة إضافة سريعة: عملية مدين أو دائن، حساب، '
              'كلمة مرور أو مستند.',
        ),
        CoachStep(
          target: shell.tabBarKey(1),
          title: 'الحسابات',
          message: 'تصنيفاتك وحساباتك وعملياتها وتقاريرها.',
        ),
        CoachStep(
          target: shell.tabBarKey(2),
          title: 'كلمات المرور',
          message: 'خزنة مشفرة لبيانات الدخول.',
        ),
        CoachStep(
          target: shell.tabBarKey(3),
          title: 'المستندات',
          message: 'مستنداتك المهمة وصورها وملفاتها المشفرة.',
        ),
      ],
    ];
  }

  PreferredSizeWidget _appBar() => JibiTopBar(
    vaultKey: _tipVault,
    searchKey: _tipSearch,
    themeKey: _tipTheme,
    settingsKey: _tipSettings,
    onSearch: _openSearch,
    onThemeChanged: (mode) => unawaited(_setTheme(mode)),
    onSettings: _openSettings,
    onVault: () => _shellKey.currentState?.selectTab(2),
    onProfile: _openSettings,
  );

  Widget _previewShell() => JibiAppShell(
    key: _shellKey,
    appBar: _appBar(),
    quickActions: [
      JibiQuickAction(
        label: 'إضافة',
        icon: Icons.add,
        onPressed: () => widget.onPrimaryAction?.call(0),
      ),
    ],
    tabs: [
      JibiShellTab(
        label: 'الرئيسية',
        icon: Icons.home_outlined,
        selectedIcon: Icons.home,
        child: HomeDashboard(
          onAddTransaction: () => widget.onPrimaryAction?.call(0),
          onAddAccount: () => widget.onPrimaryAction?.call(1),
          onAddPassword: () => widget.onPrimaryAction?.call(2),
          onAddDocument: () => widget.onPrimaryAction?.call(3),
        ),
      ),
      _placeholderTab(
        label: 'الحسابات',
        icon: Icons.people_outline,
        selectedIcon: Icons.people,
        message: 'ستظهر حساباتك هنا.',
        actionIndex: 1,
      ),
      _placeholderTab(
        label: 'كلمات المرور',
        icon: Icons.key_outlined,
        selectedIcon: Icons.key,
        message: 'ستظهر كلمات المرور المحفوظة هنا.',
        actionIndex: 2,
      ),
      _placeholderTab(
        label: 'المستندات',
        icon: Icons.folder_outlined,
        selectedIcon: Icons.folder,
        message: 'ستظهر مستنداتك هنا.',
        actionIndex: 3,
      ),
    ],
  );

  JibiShellTab _placeholderTab({
    required String label,
    required IconData icon,
    required IconData selectedIcon,
    required String message,
    required int actionIndex,
  }) => JibiShellTab(
    label: label,
    icon: icon,
    selectedIcon: selectedIcon,
    child: JibiEmptyState(
      title: 'لا توجد عناصر بعد',
      message: message,
      actionLabel: 'إضافة',
      onAction: () => widget.onPrimaryAction?.call(actionIndex),
    ),
  );

  void _openBookAccountForm() {
    final application = _application!;
    unawaited(() async {
      final categories = await application.book.categories.summaries();
      final navigatorContext = _navigatorKey.currentContext;
      if (!mounted ||
          _locked ||
          navigatorContext == null ||
          !navigatorContext.mounted) {
        return;
      }
      if (categories.isEmpty) {
        _showMessage('أنشئ تصنيفاً أولاً ثم أضف إليه حساباً.');
        await openCategoryForm(navigatorContext, application.book);
      } else {
        await openAccountForm(navigatorContext, application.book);
      }
    }());
  }

  Future<void> _openBookTransaction() async {
    final application = _application!;
    try {
      final pickerContext = _navigatorKey.currentContext;
      if (!mounted ||
          _locked ||
          pickerContext == null ||
          !pickerContext.mounted) {
        return;
      }
      final account = await pickBookAccount(pickerContext, application.book);
      final formContext = _navigatorKey.currentContext;
      if (account == null ||
          !mounted ||
          _locked ||
          formContext == null ||
          !formContext.mounted) {
        return;
      }
      await openTransactionForm(
        formContext,
        application.book,
        account: account,
      );
    } on Object {
      if (mounted) _showMessage('تعذر تحميل الحسابات. حاول مرة أخرى.');
    }
  }

  void _openWalletForm() {
    final application = _application!;
    final navigatorContext = _navigatorKey.currentContext;
    if (!mounted ||
        _locked ||
        navigatorContext == null ||
        !navigatorContext.mounted) {
      return;
    }
    unawaited(openWalletForm(navigatorContext, application.book));
  }

  void _openWallet(String walletId) {
    final application = _application!;
    final navigatorContext = _navigatorKey.currentContext;
    if (!mounted ||
        _locked ||
        navigatorContext == null ||
        !navigatorContext.mounted) {
      return;
    }
    unawaited(
      pushShellPage<void>(
        navigatorContext,
        WalletDetailPage(book: application.book, walletId: walletId),
      ),
    );
  }

  void _openWalletsList() {
    final application = _application!;
    final navigatorContext = _navigatorKey.currentContext;
    if (!mounted ||
        _locked ||
        navigatorContext == null ||
        !navigatorContext.mounted) {
      return;
    }
    unawaited(
      pushShellPage<void>(
        navigatorContext,
        WalletsListPage(book: application.book),
      ),
    );
  }

  /// Gate for exporting or sharing financial data: the fingerprint first
  /// (unless the user turned it off), the PIN when it is unavailable, declined
  /// or fails.
  Future<bool> _authorizeExport(
    BuildContext context, {
    required String title,
  }) async {
    final application = _application;
    if (application == null) return false;
    final biometric = await application.confirmWithBiometrics();
    if (biometric == true) return true;
    if (!mounted || !context.mounted) return false;
    final pin = await askPinDialog(
      context,
      title: title,
      message: biometric == false
          ? 'لم يتم التحقق بالبصمة. أدخل رمز PIN لتصدير البيانات أو مشاركتها.'
          : 'أدخل رمز PIN لتصدير البيانات أو مشاركتها.',
    );
    if (pin == null) return false;
    try {
      final result = await application.security.unlockWithPin(pin);
      if (result.authenticated) return true;
      final retryAfter = result.retryAfter;
      if (mounted) {
        _showMessage(
          result.reason == 'pin_locked_out' && retryAfter != null
              ? pinLockoutMessage(retryAfter)
              : 'رمز PIN غير صحيح.',
        );
      }
    } on Object {
      if (mounted) _showMessage('تعذر التحقق من رمز PIN.');
    }
    return false;
  }

  void _openCredentialForm() {
    final application = _application!;
    _navigatorKey.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => CredentialFormPage(controller: application.credentials),
      ),
    );
  }

  void _openDocumentForm() {
    final application = _application!;
    _navigatorKey.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => DocumentFormPage(controller: application.documents),
      ),
    );
  }

  Future<void> _setTheme(ThemeMode mode) async {
    try {
      final application = _application;
      if (application != null) {
        await application.saveSettings(
          application.settings.copyWith(
            themePreference: switch (mode) {
              ThemeMode.system => AppThemePreference.system,
              ThemeMode.light => AppThemePreference.light,
              ThemeMode.dark => AppThemePreference.dark,
            },
          ),
        );
      }
      if (mounted) setState(() => _themeMode = mode);
    } on Object {
      if (mounted) _showMessage('تعذر حفظ المظهر. حاول مرة أخرى.');
    }
  }

  /// Jumps from a recent-activity row to the screen that owns that kind.
  void _openActivity(RecentActivityKind kind) {
    switch (kind) {
      case RecentActivityKind.transaction:
        _shellKey.currentState?.selectTab(1);
      case RecentActivityKind.credential:
        _shellKey.currentState?.selectTab(2);
      case RecentActivityKind.document:
        _shellKey.currentState?.selectTab(3);
    }
  }

  Future<void> _openSettings() async {
    final application = _application;
    if (application == null) {
      return;
    }

    await _navigatorKey.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('الإعدادات')),
          body: SettingsHubPage(application: application),
        ),
      ),
    );
    // A backup may have been made in Settings; refresh the dashboard banner.
    if (mounted) setState(() {});
  }

  /// A tapped backup reminder goes straight to the backup screen.
  Future<void> _openBackupSettings() async {
    final application = _application;
    if (application == null) {
      return;
    }
    await _navigatorKey.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => BackupSettingsPage(application: application),
      ),
    );
    if (mounted) setState(() {});
  }

  void _openSearch() {
    final application = _application;
    if (application == null) {
      return;
    }
    _navigatorKey.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => GlobalSearchPage(application: application),
      ),
    );
  }

  void _showMessage(String message, {Duration? duration}) {
    final context = _navigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: duration ?? const Duration(seconds: 4),
      ),
    );
  }
}

class _LockScreen extends StatefulWidget {
  const _LockScreen({
    required this.security,
    required this.biometricsEnabled,
    required this.biometricsAvailable,
    required this.onPinReset,
    this.onPinUnlocked,
  });

  final SecurityService security;
  final bool biometricsEnabled;
  final Future<bool> Function() biometricsAvailable;

  /// Called with the new PIN right after a forgotten PIN was replaced (the
  /// phone confirmed the person first). The PIN is not kept by the lock screen.
  final Future<void> Function(String pin) onPinReset;

  /// Called with the PIN right after it unlocked the app (never after a
  /// biometric unlock). The PIN is not kept by the lock screen.
  final Future<void> Function(String pin)? onPinUnlocked;

  @override
  State<_LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<_LockScreen> with WidgetsBindingObserver {
  static const _noDeviceAuthText =
      'لا توجد بصمة ولا قفل شاشة مفعّل على هذا الهاتف للتحقق من هويتك. '
      'فعّل أحدهما من إعدادات الهاتف ثم أعد المحاولة.';

  final _pin = TextEditingController();
  final _newPin = TextEditingController();
  final _confirmPin = TextEditingController();
  bool _submitting = false;
  bool _biometricReady = false;
  bool _autoPrompted = false;

  /// Second step of a forgotten-PIN reset: the phone confirmed the person and
  /// a new PIN is being chosen. Lives here, not in a dialog, because dialogs
  /// are routes of the navigator that sits under this screen.
  bool _creatingPin = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_resolveBiometrics());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pin.dispose();
    _newPin.dispose();
    _confirmPin.dispose();
    super.dispose();
  }

  Future<void> _resolveBiometrics() async {
    if (!widget.biometricsEnabled) return;
    var available = false;
    try {
      available = await widget.biometricsAvailable();
    } on Object {
      available = false;
    }
    if (!mounted) return;
    setState(() => _biometricReady = available);
    _autoPromptIfForeground();
  }

  /// Prompts once per foreground session so the PIN field stays the fallback
  /// and a cancelled prompt is never re-shown in a loop.
  void _autoPromptIfForeground() {
    if (_autoPrompted || !_biometricReady || _submitting) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    _autoPrompted = true;
    unawaited(_unlockWithBiometrics(automatic: true));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _autoPrompted = false;
      case AppLifecycleState.resumed:
        _autoPromptIfForeground();
      case AppLifecycleState.inactive:
        break;
    }
  }

  Future<void> _unlockWithPin() async {
    final pin = _pin.text;
    final unlocked = await _unlock(
      () => widget.security.unlockWithPin(pin),
      failureMessage: 'رمز PIN غير صحيح.',
    );
    if (mounted) _pin.clear();
    if (unlocked) {
      unawaited(widget.onPinUnlocked?.call(pin) ?? Future<void>.value());
    }
  }

  Future<void> _unlockWithBiometrics({bool automatic = false}) => _unlock(
    () => ExternalActivityScope.of(context)(
      widget.security.authenticateBiometrically,
    ),
    failureMessage: 'لم يتم التحقق بالبصمة. يمكنك استخدام رمز PIN.',
    silentFailure: automatic,
  );

  DeviceVerifiedPinReset? get _pinReset {
    final service = widget.security;
    return service is DeviceVerifiedPinReset
        ? service as DeviceVerifiedPinReset
        : null;
  }

  /// "نسيت رمز PIN؟": the phone confirms the person (fingerprint or screen
  /// lock), then a new PIN is chosen here. No file, backup or other screen is
  /// involved, and nothing stored is touched.
  Future<void> _forgotPin() async {
    if (_submitting) return;
    final reset = _pinReset;
    if (reset == null) {
      _showMessage(_noDeviceAuthText);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      if (!await reset.canVerifyDeviceIdentity()) {
        _showMessage(_noDeviceAuthText);
        return;
      }
      if (!mounted) return;
      final result = await ExternalActivityScope.of(context)(
        reset.verifyDeviceIdentity,
      );
      if (!mounted) return;
      if (result.authenticated) {
        setState(() => _creatingPin = true);
      } else {
        _showMessage(
          result.reason == 'device_auth_unavailable'
              ? _noDeviceAuthText
              : 'لم يتم التحقق من هويتك، فلم يتغير رمز PIN.',
        );
      }
    } on AppException catch (error) {
      _showMessage(error.userMessage);
    } on Object {
      _showMessage('تعذر التحقق من هويتك. حاول مرة أخرى.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _saveNewPin() async {
    final reset = _pinReset;
    if (_submitting || reset == null) return;
    final pin = _newPin.text;
    if (pin != _confirmPin.text) {
      _showMessage('الرمزان غير متطابقين.');
      return;
    }
    if (!PinPolicy.isValid(pin)) {
      _showMessage('رمز PIN يجب أن يتكون من 6 أرقام على الأقل.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await reset.resetPin(newPin: pin);
      // The app unlocks itself (lock state stream) and this screen goes away.
      _newPin.clear();
      _confirmPin.clear();
      unawaited(widget.onPinReset(pin));
    } on AppException catch (error) {
      if (!mounted) return;
      // An expired confirmation starts over; anything else can be retried.
      if (error.code == 'pin_reset_not_authorized') _leaveReset();
      _showMessage(error.userMessage);
    } on Object {
      _showMessage('تعذر إنشاء رمز PIN الجديد. حاول مرة أخرى.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _leaveReset() {
    _newPin.clear();
    _confirmPin.clear();
    setState(() {
      _creatingPin = false;
      _error = null;
    });
  }

  /// Returns whether the app was unlocked.
  Future<bool> _unlock(
    Future<AuthenticationResult> Function() authenticate, {
    required String failureMessage,
    bool silentFailure = false,
  }) async {
    if (_submitting) return false;
    // Temporary diagnostic for the startup-performance investigation: marks
    // the moment a real (not ignored-because-already-submitting) unlock
    // attempt starts, so `UnlockTiming.reportHomeVisible` below can print the
    // true button-press → Home-frame wall-clock gap.
    UnlockTiming.markPressed();
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final result = await authenticate();
      if (!mounted) {
        return result.authenticated;
      }
      if (!result.authenticated && !silentFailure) {
        _showMessage(_failureText(result, failureMessage));
      }
      return result.authenticated;
    } on AppException catch (error) {
      if (mounted && !silentFailure) {
        _showMessage(error.userMessage);
      }
      return false;
    } on Object {
      if (mounted && !silentFailure) {
        _showMessage('تعذر فتح القفل. حاول مرة أخرى.');
      }
      return false;
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  void _showMessage(String message) {
    if (mounted) setState(() => _error = message);
  }

  static String _failureText(AuthenticationResult result, String fallback) {
    final retryAfter = result.retryAfter;
    return result.reason == 'pin_locked_out' && retryAfter != null
        ? pinLockoutMessage(retryAfter)
        : fallback;
  }

  Widget _errorLine(BuildContext context) => Semantics(
    liveRegion: true,
    child: Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(
        _error!,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
    ),
  );

  List<Widget> _enterPinChildren(BuildContext context) => [
    PinField(
      key: const Key('lock-pin'),
      controller: _pin,
      label: 'رمز PIN',
      onSubmitted: (_) => _unlockWithPin(),
    ),
    if (_error != null) _errorLine(context),
    const SizedBox(height: 12),
    FilledButton(
      key: const Key('lock-unlock-button'),
      onPressed: _submitting ? null : _unlockWithPin,
      child: Text(_submitting ? 'جارٍ التحقق…' : 'فتح القفل'),
    ),
    if (widget.biometricsEnabled && _biometricReady)
      TextButton.icon(
        onPressed: _submitting ? null : _unlockWithBiometrics,
        icon: const Icon(Icons.fingerprint),
        label: const Text('استخدام البصمة'),
      ),
    TextButton(
      key: const Key('lock-forgot-pin'),
      onPressed: _submitting ? null : _forgotPin,
      child: const Text('نسيت رمز PIN؟'),
    ),
  ];

  List<Widget> _createPinChildren(BuildContext context) => [
    Text(
      'تم التحقق من هويتك. اختر رمز PIN جديدًا من 6 أرقام على الأقل. '
      'بياناتك كما هي ولن تتأثر.',
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodyMedium,
    ),
    const SizedBox(height: 16),
    PinField(
      key: const Key('lock-new-pin'),
      controller: _newPin,
      autofocus: true,
      label: 'رمز PIN الجديد',
      textInputAction: TextInputAction.next,
    ),
    const SizedBox(height: 12),
    PinField(
      key: const Key('lock-confirm-pin'),
      controller: _confirmPin,
      label: 'تأكيد رمز PIN',
      onSubmitted: (_) => _saveNewPin(),
    ),
    if (_error != null) _errorLine(context),
    const SizedBox(height: 12),
    FilledButton(
      key: const Key('lock-save-new-pin'),
      onPressed: _submitting ? null : _saveNewPin,
      child: Text(_submitting ? 'جارٍ الحفظ…' : 'حفظ رمز PIN والدخول'),
    ),
    TextButton(
      key: const Key('lock-cancel-reset'),
      onPressed: _submitting ? null : _leaveReset,
      child: const Text('رجوع'),
    ),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(child: JibiAppIcon(size: 96)),
                  const SizedBox(height: 16),
                  Text(
                    _creatingPin ? 'إنشاء رمز PIN جديد' : 'جيبي مقفل',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 24),
                  ..._creatingPin
                      ? _createPinChildren(context)
                      : _enterPinChildren(context),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<String?> _askSecret(
  BuildContext context, {
  required String title,
  required String label,
}) async {
  final controller = TextEditingController();
  try {
    return await showJibiDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: PinField(
          controller: controller,
          autofocus: true,
          label: label,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('متابعة'),
          ),
        ],
      ),
    );
  } finally {
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
  }
}
