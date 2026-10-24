import 'package:flutter/material.dart';

import '../../core/errors/app_exception.dart';
import '../../core/models/models.dart';
import '../../core/security/security_primitives.dart';
import '../../features/book/domain/book_labels.dart';
import '../../features/book/domain/book_preferences.dart';
import '../../shared/widgets/jibi_design.dart';
import '../../shared/widgets/jibi_feedback.dart';
import '../../shared/widgets/jibi_walkthrough.dart';
import '../../shared/widgets/pin_field.dart';
import '../currency_management_page.dart';
import '../jibi_application.dart';
import 'settings_widgets.dart';

/// "الإعدادات العامة" (المتطلبات 53–55): appearance, currency, how the
/// accounts book is shown and entered, security, and the advanced wording of
/// the two sides.
class GeneralSettingsPage extends StatefulWidget {
  const GeneralSettingsPage({required this.application, super.key});

  final JibiApplication application;

  @override
  State<GeneralSettingsPage> createState() => _GeneralSettingsPageState();
}

class _GeneralSettingsPageState extends State<GeneralSettingsPage> {
  static const _clipboardChoices = [15, 30, 60, 120];

  late final TextEditingController _debitLabel = TextEditingController(
    text: widget.application.settings.debitLabel,
  );
  late final TextEditingController _creditLabel = TextEditingController(
    text: widget.application.settings.creditLabel,
  );
  bool _saving = false;
  String? _labelsError;

  JibiApplication get _application => widget.application;

  @override
  void dispose() {
    _debitLabel.dispose();
    _creditLabel.dispose();
    super.dispose();
  }

  Future<void> _save(AppSettings settings) async {
    setState(() => _saving = true);
    await saveSettingsOrShow(context, _application, settings);
    if (mounted) setState(() => _saving = false);
  }

  /// Snaps a stored value that is not one of the choices to the nearest one,
  /// so the dropdown always has a valid selection.
  static int _clipboardSeconds(Duration value) => _clipboardChoices.reduce(
    (best, choice) =>
        (choice - value.inSeconds).abs() < (best - value.inSeconds).abs()
        ? choice
        : best,
  );

  Future<void> _setBiometrics(bool enabled) async {
    if (enabled && !await _confirmBiometrics()) return;
    if (!mounted) return;
    await _save(_application.settings.copyWith(biometricsEnabled: enabled));
  }

  /// Turning biometrics on requires an enrolled biometric and one successful
  /// prompt, so the lock screen never offers a method that cannot succeed.
  Future<bool> _confirmBiometrics() async {
    setState(() => _saving = true);
    try {
      if (!await _application.biometricsAvailable()) {
        if (mounted) {
          showJibiMessage(
            context,
            'لا توجد بصمة مسجلة على هذا الجهاز. سجّل بصمتك في إعدادات الهاتف أولاً.',
          );
        }
        return false;
      }
      final result = await _application.runExternalActivity(
        _application.security.reauthenticate,
      );
      if (!result.authenticated && mounted) {
        showJibiMessage(context, 'لم يتم التحقق بالبصمة، لذا لم يتم التفعيل.');
      }
      return result.authenticated;
    } on Object {
      if (mounted) showJibiMessage(context, 'تعذر التحقق بالبصمة.');
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Forgets which tours were shown, so each appears again, and switches the
  /// hints on.
  Future<void> _replayTips(AppSettings settings) async {
    await _save(
      settings.copyWith(showCoachMarks: true, seenTours: const <String>{}),
    );
    if (mounted) {
      showJibiMessage(
        context,
        'ستظهر التلميحات من جديد عند فتح كل شاشة.',
      );
    }
  }

  Future<void> _saveLabels() async {
    final AppSettings next;
    try {
      next = _application.settings.withSideLabels(
        debit: _debitLabel.text,
        credit: _creditLabel.text,
      );
    } on AppException catch (error) {
      setState(() => _labelsError = error.userMessage);
      return;
    }
    setState(() => _labelsError = null);
    await _save(next);
    if (mounted) {
      // Show what was really stored (blank fields become the standard words).
      _debitLabel.text = next.debitLabel ?? '';
      _creditLabel.text = next.creditLabel ?? '';
    }
  }

  Future<void> _resetLabels() async {
    _debitLabel.clear();
    _creditLabel.clear();
    setState(() => _labelsError = null);
    await _save(_application.settings.withSideLabels());
  }

  Future<void> _changePin() async {
    final current = TextEditingController();
    final next = TextEditingController();
    final confirmation = TextEditingController();
    String? error;
    final submitted = await showJibiDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('تغيير رمز PIN'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final entry in [
                (current, 'رمز PIN الحالي'),
                (next, 'رمز PIN الجديد'),
                (confirmation, 'تأكيد رمز PIN الجديد'),
              ]) ...[
                PinField(
                  controller: entry.$1,
                  autofocus: identical(entry.$1, current),
                  label: entry.$2,
                  errorText: identical(entry.$1, confirmation) ? error : null,
                ),
                const SizedBox(height: 12),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () {
                if (next.text != confirmation.text) {
                  setDialogState(
                    () => error = 'الرمزان الجديدان غير متطابقين.',
                  );
                  return;
                }
                if (!PinPolicy.isValid(next.text)) {
                  setDialogState(
                    () => error = 'رمز PIN يجب أن يتكون من 6 أرقام على الأقل.',
                  );
                  return;
                }
                Navigator.pop(dialogContext, true);
              },
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    final currentPin = current.text;
    final newPin = next.text;
    current.dispose();
    next.dispose();
    confirmation.dispose();
    if (submitted != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await _application.security.changePin(
        currentPin: currentPin,
        newPin: newPin,
      );
      if (mounted) showJibiMessage(context, 'تم تغيير رمز PIN بنجاح.');
    } on AppException catch (error) {
      if (mounted) showJibiMessage(context, error.userMessage);
    } on Object {
      if (mounted) showJibiMessage(context, 'تعذر تغيير رمز PIN.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// The same sample date written in [format], so the user sees the result.
  static String _dateExample(DateDisplayFormat format) =>
      BookPreferences(dateFormat: format).date('2026-09-20');

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('الإعدادات العامة')),
    body: ValueListenableBuilder<AppSettings>(
      valueListenable: _application.settingsListenable,
      builder: (context, settings, _) => ListView(
        key: const Key('general-settings'),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          if (_saving) const LinearProgressIndicator(minHeight: 3),
          SettingsGroup(
            title: 'المظهر واللغة',
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      'المظهر',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  SegmentedButton<AppThemePreference>(
                    key: const Key('general-theme'),
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: AppThemePreference.system,
                        label: Text('النظام'),
                        icon: Icon(Icons.smartphone_outlined, size: 17),
                      ),
                      ButtonSegment(
                        value: AppThemePreference.light,
                        label: Text('فاتح'),
                        icon: Icon(Icons.light_mode_outlined, size: 17),
                      ),
                      ButtonSegment(
                        value: AppThemePreference.dark,
                        label: Text('داكن'),
                        icon: Icon(Icons.dark_mode_outlined, size: 17),
                      ),
                    ],
                    selected: {settings.themePreference},
                    onSelectionChanged: _saving
                        ? null
                        : (selection) => _save(
                            settings.copyWith(
                              themePreference: selection.first,
                            ),
                          ),
                  ),
                ],
              ),
              ListTile(
                key: const Key('general-language'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.language),
                title: const Text('اللغة'),
                subtitle: Text(
                  'العربية هي اللغة المتاحة حالياً.',
                  style: TextStyle(fontSize: 12, color: context.jibiMuted),
                ),
                trailing: const Text(
                  'العربية',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          SettingsGroup(
            title: 'العملة',
            children: [
              DropdownButtonFormField<String>(
                key: ValueKey('currency-${settings.defaultCurrencyCode}'),
                initialValue: settings.defaultCurrencyCode,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'العملة الأساسية',
                ),
                items: [
                  for (final currency
                      in _application.currencyRegistry.activeCurrencies)
                    DropdownMenuItem(
                      value: currency.code,
                      child: Text('${currency.code} — ${currency.name}'),
                    ),
                ],
                onChanged: _saving
                    ? null
                    : (code) {
                        if (code != null) {
                          _save(settings.copyWith(defaultCurrencyCode: code));
                        }
                      },
              ),
              SettingsTile(
                key: const Key('general-decimals'),
                icon: Icons.pin_outlined,
                title: 'المنازل العشرية',
                subtitle:
                    'تُحدَّد لكل عملة على حدة، والافتراضي بلا كسور.',
                onTap: () => openSettingsPage(
                  context,
                  CurrencyManagementPage(application: _application),
                ),
              ),
            ],
          ),
          SettingsGroup(
            title: 'عرض العمليات',
            children: [
              DropdownButtonFormField<DateDisplayFormat>(
                key: ValueKey('date-${settings.dateFormat.name}'),
                initialValue: settings.dateFormat,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'تنسيق التاريخ'),
                items: [
                  for (final format in DateDisplayFormat.values)
                    DropdownMenuItem(
                      value: format,
                      child: Text(
                        _dateExample(format),
                        textDirection: TextDirection.ltr,
                        textAlign: TextAlign.end,
                      ),
                    ),
                ],
                onChanged: _saving
                    ? null
                    : (format) {
                        if (format != null) {
                          _save(settings.copyWith(dateFormat: format));
                        }
                      },
              ),
              SwitchListTile(
                key: const Key('general-show-time'),
                contentPadding: EdgeInsets.zero,
                title: const Text('عرض الوقت في العمليات'),
                subtitle: const Text('يظهر تحت التاريخ في جدول الحساب.'),
                value: settings.showTransactionTime,
                onChanged: _saving
                    ? null
                    : (value) =>
                          _save(settings.copyWith(showTransactionTime: value)),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      'ترتيب العمليات',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  SegmentedButton<bool>(
                    key: const Key('general-order'),
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: true, label: Text('الأحدث أولاً')),
                      ButtonSegment(value: false, label: Text('الأقدم أولاً')),
                    ],
                    selected: {settings.newestFirst},
                    onSelectionChanged: _saving
                        ? null
                        : (selection) =>
                              _save(settings.copyWith(newestFirst: selection.first)),
                  ),
                ],
              ),
              SwitchListTile(
                key: const Key('general-hide-balances'),
                contentPadding: EdgeInsets.zero,
                title: const Text('إخفاء الأرصدة'),
                subtitle: const Text(
                  'يستبدل الأرصدة والإجماليات في شاشات الحسابات بنقاط.',
                ),
                value: settings.hideBalances,
                onChanged: _saving
                    ? null
                    : (value) => _save(settings.copyWith(hideBalances: value)),
              ),
              SwitchListTile(
                key: const Key('general-confirm-delete'),
                contentPadding: EdgeInsets.zero,
                title: const Text('تأكيد قبل الحذف'),
                subtitle: const Text(
                  'عند إيقافه تُحذف العملية فوراً مع بقاء خيار التراجع.',
                ),
                value: settings.confirmBeforeDelete,
                onChanged: _saving
                    ? null
                    : (value) =>
                          _save(settings.copyWith(confirmBeforeDelete: value)),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      'العملية الافتراضية عند الإضافة',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  SegmentedButton<EntryType>(
                    key: const Key('general-default-type'),
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(
                        value: EntryType.debit,
                        label: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(BookLabels.fromSettings(settings).debit),
                        ),
                      ),
                      ButtonSegment(
                        value: EntryType.credit,
                        label: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(BookLabels.fromSettings(settings).credit),
                        ),
                      ),
                    ],
                    selected: {settings.defaultEntryType},
                    onSelectionChanged: _saving
                        ? null
                        : (selection) => _save(
                            settings.copyWith(defaultEntryType: selection.first),
                          ),
                  ),
                ],
              ),
            ],
          ),
          SettingsGroup(
            title: 'المساعدة والتلميحات',
            children: [
              SwitchListTile(
                key: const Key('general-tips'),
                contentPadding: EdgeInsets.zero,
                title: const Text('التلميحات فوق الأزرار'),
                subtitle: const Text(
                  'مؤشرات متحركة تعرّفك بوظيفة كل زر عند فتح الشاشات لأول مرة.',
                ),
                value: settings.showCoachMarks,
                onChanged: _saving
                    ? null
                    : (value) => _save(settings.copyWith(showCoachMarks: value)),
              ),
              SettingsTile(
                key: const Key('general-replay-tips'),
                icon: Icons.tips_and_updates_outlined,
                title: 'إعادة عرض التلميحات',
                subtitle: 'تظهر من جديد عند فتح الرئيسية والحسابات وكشف الحساب.',
                onTap: _saving ? null : () => _replayTips(settings),
              ),
              SettingsTile(
                key: const Key('general-replay-tour'),
                icon: Icons.slideshow_outlined,
                title: 'الجولة التعريفية',
                subtitle: 'بطاقات تعرض مزايا التطبيق الأساسية.',
                onTap: () => showJibiWalkthrough(context),
              ),
            ],
          ),
          SettingsGroup(
            title: 'الأمان والخصوصية',
            children: [
              DropdownButtonFormField<AutoLockDuration>(
                key: ValueKey('lock-${settings.autoLockDuration.name}'),
                initialValue: settings.autoLockDuration,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'القفل التلقائي'),
                items: const [
                  DropdownMenuItem(
                    value: AutoLockDuration.immediate,
                    child: Text('فوراً'),
                  ),
                  DropdownMenuItem(
                    value: AutoLockDuration.oneMinute,
                    child: Text('بعد دقيقة'),
                  ),
                  DropdownMenuItem(
                    value: AutoLockDuration.fiveMinutes,
                    child: Text('بعد 5 دقائق'),
                  ),
                  DropdownMenuItem(
                    value: AutoLockDuration.fifteenMinutes,
                    child: Text('بعد 15 دقيقة'),
                  ),
                ],
                onChanged: _saving
                    ? null
                    : (duration) {
                        if (duration != null) {
                          _save(settings.copyWith(autoLockDuration: duration));
                        }
                      },
              ),
              DropdownButtonFormField<int>(
                key: ValueKey('clipboard-${settings.clipboardClearAfter}'),
                initialValue: _clipboardSeconds(settings.clipboardClearAfter),
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'مسح الحافظة بعد نسخ كلمة مرور',
                ),
                items: [
                  for (final seconds in _clipboardChoices)
                    DropdownMenuItem(
                      value: seconds,
                      child: Text(
                        seconds < 60
                            ? '$seconds ثانية'
                            : seconds == 60
                            ? 'دقيقة'
                            : seconds == 120
                            ? 'دقيقتان'
                            : '${seconds ~/ 60} دقائق',
                      ),
                    ),
                ],
                onChanged: _saving
                    ? null
                    : (seconds) {
                        if (seconds != null) {
                          _save(
                            settings.copyWith(
                              clipboardClearAfter: Duration(seconds: seconds),
                            ),
                          );
                        }
                      },
              ),
              SwitchListTile(
                key: const Key('general-biometrics'),
                contentPadding: EdgeInsets.zero,
                title: const Text('الدخول بالبصمة / Face ID'),
                subtitle: const Text('التحقق السريع والآمن بالبيانات الحيوية'),
                value: settings.biometricsEnabled,
                onChanged: _saving ? null : _setBiometrics,
              ),
              SwitchListTile(
                key: const Key('general-screenshot'),
                contentPadding: EdgeInsets.zero,
                title: const Text('منع تصوير الشاشة'),
                subtitle: const Text('مفعّل افتراضياً للبيانات الحساسة'),
                value: settings.screenshotProtectionEnabled,
                onChanged: _saving
                    ? null
                    : (enabled) => _save(
                        settings.copyWith(screenshotProtectionEnabled: enabled),
                      ),
              ),
              SettingsTile(
                key: const Key('general-change-pin'),
                icon: Icons.password_outlined,
                title: 'تغيير رمز PIN السري',
                subtitle: 'يتطلب إدخال الرمز الحالي للتبديل',
                badge: '6 أرقام',
                onTap: _saving ? null : _changePin,
              ),
            ],
          ),
          SettingsGroup(
            title: 'إعدادات متقدمة',
            children: [
              ExpansionTile(
                key: const Key('general-advanced'),
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 8),
                title: const Text(
                  'تسمية المدين والدائن',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                ),
                subtitle: Text(
                  'مثلاً: مستحق لي / مستحق علي. المنطق الداخلي لا يتغير.',
                  style: TextStyle(fontSize: 12, color: context.jibiMuted),
                ),
                children: [
                  TextField(
                    key: const Key('label-debit'),
                    controller: _debitLabel,
                    enabled: !_saving,
                    maxLength: maxSideLabelLength,
                    decoration: const InputDecoration(
                      labelText: 'بدل كلمة «مدين»',
                      hintText: 'مدين',
                    ),
                  ),
                  TextField(
                    key: const Key('label-credit'),
                    controller: _creditLabel,
                    enabled: !_saving,
                    maxLength: maxSideLabelLength,
                    decoration: const InputDecoration(
                      labelText: 'بدل كلمة «دائن»',
                      hintText: 'دائن',
                    ),
                  ),
                  if (_labelsError != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        _labelsError!,
                        key: const Key('labels-error'),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          key: const Key('labels-save'),
                          onPressed: _saving ? null : _saveLabels,
                          child: const Text('حفظ التسمية'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        key: const Key('labels-reset'),
                        onPressed: _saving ? null : _resetLabels,
                        child: const Text('الأصل'),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
