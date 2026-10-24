import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_info.dart';
import '../../core/platform/external_link_launcher.dart';
import '../../shared/widgets/external_activity_scope.dart';
import '../../shared/widgets/jibi_app_icon.dart';
import '../../shared/widgets/jibi_design.dart';
import '../../shared/widgets/jibi_feedback.dart';
import '../../shared/widgets/whatsapp_glyph.dart';
import 'privacy_policy_page.dart';
import 'support_info.dart';

/// «تواصل معنا»: the developer's support channels. WhatsApp and the dialer
/// open with the number filled in but the number itself is never shown.
class ContactUsPage extends StatefulWidget {
  const ContactUsPage({
    this.launcher = const AndroidExternalLinkLauncher(),
    super.key,
  });

  final ExternalLinkLauncher launcher;

  @override
  State<ContactUsPage> createState() => _ContactUsPageState();
}

class _ContactUsPageState extends State<ContactUsPage> {
  static const _whatsAppGreen = Color(0xFF25D366);
  static const _mailBlue = Color(0xFF2F80ED);

  bool _busy = false;

  /// Starts [open] as an external activity; when nothing could handle it,
  /// releases the lock guard and tells the user with [unavailable].
  Future<void> _launch(
    Future<bool> Function() open, {
    required String unavailable,
    Future<void> Function()? onUnavailable,
  }) async {
    if (_busy) return;
    _busy = true;
    // Taken before the await: the page may be gone when the app comes back.
    final run = ExternalActivityScope.of(context);
    final release = ExternalActivityScope.releaseOf(context);
    var opened = false;
    try {
      opened = await run(open, holdUntilResumed: true);
    } on Object {
      opened = false;
    } finally {
      _busy = false;
    }
    if (opened) return;
    // Nothing started, so the app will never pause and resume: end the guard.
    release();
    await onUnavailable?.call();
    if (mounted) showJibiMessage(context, unavailable);
  }

  Future<void> _whatsApp() => _launch(
    () => widget.launcher.openWhatsApp(
      phone: SupportContact.phone,
      message: SupportContact.whatsAppMessage(),
    ),
    unavailable: 'تعذر فتح واتساب على هذا الجهاز.',
  );

  Future<void> _call() => _launch(
    () => widget.launcher.dial(SupportContact.phone),
    unavailable: 'لا يوجد تطبيق اتصال على هذا الجهاز.',
  );

  Future<void> _email() => _launch(
    () => widget.launcher.composeEmail(
      to: SupportContact.email,
      subject: SupportContact.emailSubject(),
      body: SupportContact.emailBody(),
    ),
    // Without a mail app the address is at least on the clipboard.
    unavailable:
        'لا يوجد تطبيق بريد على هذا الجهاز، نُسخ العنوان: '
        '${SupportContact.email}',
    onUnavailable: () =>
        Clipboard.setData(const ClipboardData(text: SupportContact.email)),
  );

  Future<void> _website() => _launch(
    () => widget.launcher.openWebsite(SupportContact.website),
    unavailable: 'تعذر فتح المتصفح.',
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    key: const Key('contact-us'),
    appBar: AppBar(title: const Text('تواصل معنا')),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        const _Banner(),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 4, bottom: 10),
          child: Text(
            'اختر وسيلة التواصل',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: context.jibiMuted,
            ),
          ),
        ),
        _ContactCard(
          key: const Key('contact-whatsapp'),
          color: _whatsAppGreen,
          icon: const WhatsAppGlyph(size: 30),
          title: 'واتساب',
          subtitle: 'محادثة مباشرة برسالة طلب دعم جاهزة',
          onTap: _whatsApp,
        ),
        const SizedBox(height: 12),
        _ContactCard(
          key: const Key('contact-call'),
          color: JibiColors.deepGreenLight,
          icon: const Icon(Icons.call_rounded, color: Colors.white, size: 26),
          title: 'اتصال',
          subtitle: 'افتح شاشة الاتصال للتحدث مع المطور',
          onTap: _call,
        ),
        const SizedBox(height: 12),
        _ContactCard(
          key: const Key('contact-email'),
          color: _mailBlue,
          icon: const Icon(Icons.mail_rounded, color: Colors.white, size: 26),
          title: 'البريد الإلكتروني',
          subtitle: SupportContact.email,
          onTap: _email,
        ),
        const SizedBox(height: 12),
        _ContactCard(
          key: const Key('contact-website'),
          color: JibiColors.gold,
          icon: const Icon(
            Icons.language,
            color: JibiColors.onTintInk,
            size: 26,
          ),
          title: 'الموقع الإلكتروني',
          subtitle: SupportContact.websiteLabel,
          onTap: _website,
        ),
        const SizedBox(height: 20),
        const _Note(),
        const SizedBox(height: 8),
        Align(
          child: TextButton.icon(
            key: const Key('contact-privacy'),
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => const PrivacyPolicyPage(),
              ),
            ),
            icon: const Icon(Icons.privacy_tip_outlined),
            label: const Text('سياسة الخصوصية'),
          ),
        ),
        Center(
          child: Text(
            'جيبي • الإصدار ${AppInfo.display}',
            style: TextStyle(fontSize: 12, color: context.jibiMuted),
          ),
        ),
      ],
    ),
  );
}

class _Banner extends StatelessWidget {
  const _Banner();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      gradient: JibiColors.heroGradient,
      borderRadius: BorderRadius.circular(22),
    ),
    child: const Row(
      children: [
        JibiAppIcon(size: 60),
        SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'الدعم الفني',
                style: TextStyle(
                  color: JibiColors.gold,
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                ),
              ),
              SizedBox(height: 6),
              Text(
                'نسعد بمساعدتك في أي مشكلة أو اقتراح أو استفسار عن جيبي.',
                style: TextStyle(color: Colors.white, fontSize: 13, height: 1.5),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _ContactCard extends StatelessWidget {
  const _ContactCard({
    required this.color,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    super.key,
  });

  final Color color;
  final Widget icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: title,
    hint: subtitle,
    excludeSemantics: true,
    onTap: onTap,
    child: JibiSoftCard(
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 54,
            height: 54,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(17),
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.35),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: icon,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: context.jibiMuted),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_left, color: context.jibiMuted),
        ],
      ),
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note();

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'الرسالة الجاهزة تتضمن رقم إصدار التطبيق فقط، ويمكنك تعديلها '
              'قبل الإرسال.',
              style: TextStyle(fontSize: 12.5, height: 1.5, color: context.jibiInk),
            ),
          ),
        ],
      ),
    );
  }
}
