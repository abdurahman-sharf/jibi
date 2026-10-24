import 'package:flutter/material.dart';

import '../../core/app_info.dart';
import '../../shared/widgets/jibi_design.dart';
import 'contact_us_page.dart';
import 'privacy_policy_text.dart';

/// «سياسة الخصوصية»: what the app stores, protects and shares, in plain
/// Arabic. The words live in [privacyPolicySections].
class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    key: const Key('privacy-policy'),
    appBar: AppBar(title: const Text('سياسة الخصوصية')),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        const _Banner(),
        const SizedBox(height: 16),
        for (final section in privacyPolicySections) ...[
          _SectionCard(section: section),
          const SizedBox(height: 12),
        ],
        Align(
          child: TextButton.icon(
            key: const Key('privacy-contact'),
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(builder: (_) => const ContactUsPage()),
            ),
            icon: const Icon(Icons.support_agent),
            label: const Text('لأي استفسار: تواصل معنا'),
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
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.verified_user_outlined, color: JibiColors.gold, size: 22),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'خصوصيتك أولًا',
                style: TextStyle(
                  color: JibiColors.gold,
                  fontWeight: FontWeight.w800,
                  fontSize: 17,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'بياناتك تبقى على جهازك ولا نرسلها إلى أي خادم.',
          style: TextStyle(color: Colors.white, fontSize: 13, height: 1.5),
        ),
        const SizedBox(height: 10),
        JibiBadge(
          'آخر تحديث: $privacyPolicyUpdated • الإصدار ${AppInfo.display}',
          background: Colors.white.withValues(alpha: 0.16),
          foreground: Colors.white,
        ),
      ],
    ),
  );
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.section});

  final PrivacyPolicySection section;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return JibiSoftCard(
      key: Key('privacy-section-${section.title}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              JibiIconBubble(
                icon: section.icon,
                tint: primary.withValues(alpha: 0.12),
                foreground: primary,
                size: 40,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  section.title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
              ),
            ],
          ),
          for (final paragraph in section.paragraphs)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                paragraph,
                style: TextStyle(height: 1.6, color: context.jibiInk),
              ),
            ),
          for (final bullet in section.bullets)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Icon(Icons.circle, size: 6, color: primary),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      bullet,
                      style: TextStyle(height: 1.6, color: context.jibiInk),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
