import 'dart:async';

import 'package:flutter/material.dart';
import 'package:jibi/core/security/security_primitives.dart';
import 'package:jibi/shared/widgets/jibi_app_icon.dart';
import 'package:jibi/shared/widgets/jibi_feedback.dart';
import 'package:jibi/shared/widgets/jibi_page.dart';
import 'package:jibi/shared/widgets/pin_field.dart';
import 'package:jibi/shared/widgets/jibi_walkthrough.dart';

/// A visual-only first-run flow: welcome, a short tour of the features, PIN
/// setup, backup note. Consumers perform PIN and restore operations.
class JibiOnboardingFlow extends StatefulWidget {
  const JibiOnboardingFlow({
    super.key,
    this.onPinSetupRequested,
    this.onPinSubmitted,
    this.onBiometricPreferenceChanged,
    this.biometricAvailability,
    this.onRestoreRequested,
    this.onCompleted,
  });

  final VoidCallback? onPinSetupRequested;
  final Future<String?> Function({
    required String pin,
    required bool biometricsEnabled,
  })?
  onPinSubmitted;
  final ValueChanged<bool>? onBiometricPreferenceChanged;

  /// Resolves to whether a biometric is enrolled on this device. When it
  /// resolves true the biometric switch is turned on by default (unless the
  /// user already touched it); when false the switch is disabled. Leave null
  /// to keep the switch always available and off by default.
  final Future<bool>? biometricAvailability;
  final Future<bool> Function()? onRestoreRequested;
  final VoidCallback? onCompleted;

  @override
  State<JibiOnboardingFlow> createState() => _JibiOnboardingFlowState();
}

class _JibiOnboardingFlowState extends State<JibiOnboardingFlow> {
  int _step = 0;
  bool _submitting = false;
  bool _useBiometrics = false;
  bool _biometricTouched = false;

  /// Null while unknown or when no availability check was requested.
  bool? _biometricAvailable;
  final _pinController = TextEditingController();
  final _confirmationController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final availability = widget.biometricAvailability;
    if (availability != null) {
      unawaited(_resolveBiometricAvailability(availability));
    }
  }

  Future<void> _resolveBiometricAvailability(Future<bool> availability) async {
    var available = false;
    try {
      available = await availability;
    } on Object {
      available = false;
    }
    if (!mounted) return;
    final enableByDefault = available && !_biometricTouched;
    setState(() {
      _biometricAvailable = available;
      if (!available) {
        _useBiometrics = false;
      } else if (enableByDefault) {
        _useBiometrics = true;
      }
    });
    if (enableByDefault || !available) {
      widget.onBiometricPreferenceChanged?.call(_useBiometrics);
    }
  }

  void _next() => setState(() => _step += 1);

  @override
  void dispose() {
    _pinController.dispose();
    _confirmationController.dispose();
    super.dispose();
  }

  Future<void> _submitPin() async {
    if (_submitting) return;
    final submit = widget.onPinSubmitted;
    if (submit == null) {
      widget.onPinSetupRequested?.call();
      _next();
      return;
    }
    final pin = _pinController.text;
    if (pin != _confirmationController.text) {
      _showError('رمزا PIN غير متطابقين.');
      return;
    }
    if (!PinPolicy.isValid(pin)) {
      _showError('رمز PIN يجب أن يتكون من 6 أرقام على الأقل.');
      return;
    }
    setState(() => _submitting = true);
    String? error;
    try {
      error = await submit(pin: pin, biometricsEnabled: _useBiometrics);
    } on Object {
      error = 'تعذر إعداد الحماية. حاول مرة أخرى.';
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
    if (!mounted) {
      return;
    }
    if (error != null) {
      _showError(error);
      return;
    }
    widget.onPinSetupRequested?.call();
    _next();
  }

  Future<void> _restore() async {
    final restore = widget.onRestoreRequested;
    if (restore == null || _submitting) return;
    setState(() => _submitting = true);
    var restored = false;
    try {
      restored = await restore();
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
    // A restored phone already knows the app: straight to the PIN step.
    if (mounted && restored) setState(() => _step = _pinStep);
  }

  static const int _pinStep = 2;

  void _showError(String message) {
    showJibiMessage(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final page = switch (_step) {
      0 => _WelcomePage(
        onStart: _next,
        onRestore: widget.onRestoreRequested == null ? null : _restore,
      ),
      1 => JibiWalkthrough(onFinished: _next, finishLabel: 'ابدأ الإعداد'),
      _pinStep => _PinSetupPage(
        useBiometrics: _useBiometrics,
        biometricAvailable: _biometricAvailable,
        onBiometricChanged: (value) {
          setState(() {
            _biometricTouched = true;
            _useBiometrics = value;
          });
          widget.onBiometricPreferenceChanged?.call(value);
        },
        pinController: _pinController,
        confirmationController: _confirmationController,
        onContinue: _submitPin,
      ),
      _ => _BackupReminderPage(onContinue: widget.onCompleted),
    };
    return Scaffold(
      body: Stack(
        children: [
          AbsorbPointer(absorbing: _submitting, child: page),
          if (_submitting)
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: LinearProgressIndicator(),
            ),
        ],
      ),
    );
  }
}

class _OnboardingScaffold extends StatelessWidget {
  const _OnboardingScaffold({
    required this.icon,
    required this.title,
    required this.description,
    required this.child,
    this.leading,
  });

  final IconData icon;

  /// Replaces the round icon (the welcome page shows the app's picture).
  final Widget? leading;
  final String title;
  final String description;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return JibiPage(
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 560),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 64),
            leading ??
                CircleAvatar(
                  radius: 42,
                  backgroundColor: colors.primaryContainer,
                  foregroundColor: colors.onPrimaryContainer,
                  child: Icon(icon, size: 44),
                ),
            const SizedBox(height: 28),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            Text(
              description,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 32),
            child,
            const SizedBox(height: 56),
          ],
        ),
      ),
    );
  }
}

class _WelcomePage extends StatelessWidget {
  const _WelcomePage({required this.onStart, this.onRestore});

  final VoidCallback onStart;
  final Future<void> Function()? onRestore;

  @override
  Widget build(BuildContext context) => _OnboardingScaffold(
    icon: Icons.account_balance_wallet_outlined,
    leading: const Center(child: JibiAppIcon(size: 132)),
    title: 'أهلاً بك في جيبي',
    description: 'محفظتك الشخصية لتنظيم أموالك وبياناتك المهمة بخصوصية.',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton(onPressed: onStart, child: const Text('ابدأ')),
        if (onRestore != null) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onRestore,
            icon: const Icon(Icons.restore_outlined),
            label: const Text('استعادة نسخة من هاتف سابق'),
          ),
        ],
      ],
    ),
  );
}

class _PinSetupPage extends StatelessWidget {
  const _PinSetupPage({
    required this.useBiometrics,
    required this.biometricAvailable,
    required this.onBiometricChanged,
    required this.pinController,
    required this.confirmationController,
    required this.onContinue,
  });

  final bool useBiometrics;
  final bool? biometricAvailable;
  final ValueChanged<bool> onBiometricChanged;
  final TextEditingController pinController;
  final TextEditingController confirmationController;
  final Future<void> Function() onContinue;

  @override
  Widget build(BuildContext context) => _OnboardingScaffold(
    icon: Icons.lock_outline,
    title: 'احمِ جيبي',
    description: 'أنشئ رمز PIN من 6 أرقام على الأقل لحماية بياناتك.',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PinField(label: 'رمز PIN الرئيسي', controller: pinController),
        const SizedBox(height: 12),
        _PinField(label: 'تأكيد رمز PIN', controller: confirmationController),
        const SizedBox(height: 12),
        SwitchListTile(
          value: useBiometrics,
          onChanged: biometricAvailable == false ? null : onBiometricChanged,
          title: const Text('تفعيل البصمة عند توفرها'),
          subtitle: biometricAvailable == false
              ? const Text('غير متاحة: سجّل بصمة في إعدادات الهاتف ثم فعّلها من إعدادات جيبي.')
              : null,
          contentPadding: EdgeInsets.zero,
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: () => onContinue(),
          child: const Text('متابعة'),
        ),
      ],
    ),
  );
}

class _PinField extends StatelessWidget {
  const _PinField({required this.label, required this.controller});

  final String label;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) => PinField(
    controller: controller,
    label: label,
    hintText: '••••••',
    maxLength: 32,
    textInputAction: TextInputAction.next,
  );
}

class _BackupReminderPage extends StatelessWidget {
  const _BackupReminderPage({required this.onContinue});

  final VoidCallback? onContinue;

  @override
  Widget build(BuildContext context) => _OnboardingScaffold(
    icon: Icons.cloud_upload_outlined,
    title: 'نسخة احتياطية اختيارية',
    description: 'يمكنك حفظ نسخة ZIP مشفرة من الإعدادات واختيار Google Drive أو التخزين المحلي من نافذة النظام.',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: onContinue,
          icon: const Icon(Icons.check_outlined),
          label: const Text('إنهاء الإعداد'),
        ),
      ],
    ),
  );
}
