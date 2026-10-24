import 'package:flutter/material.dart';

import '../../core/app_info.dart';
import '../../core/models/models.dart';
import '../../shared/widgets/jibi_design.dart';
import '../book/book_archive_page.dart';
import '../book/book_audit_page.dart';
import '../book/book_category_management_page.dart';
import '../currency_management_page.dart';
import '../jibi_application.dart';
import '../support/contact_us_page.dart';
import '../support/privacy_policy_page.dart';
import 'backup_settings_page.dart';
import 'general_settings_page.dart';
import 'settings_widgets.dart';
import 'user_profile_page.dart';

/// The settings home (المتطلبات 48): five simple entries, each opening its own
/// screen. It has no app bar of its own so it can sit in a tab; a route that
/// shows it alone wraps it in a [Scaffold].
class SettingsHubPage extends StatelessWidget {
  const SettingsHubPage({required this.application, super.key});

  final JibiApplication application;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<UserProfile>(
    valueListenable: application.profile.listenable,
    builder: (context, profile, _) => ListView(
      key: const Key('settings-hub'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text(
            'الإعدادات',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
        ),
        _ProfileCard(profile: profile),
        const SizedBox(height: 16),
        SettingsGroup(
          children: [
            SettingsTile(
              key: const Key('settings-user'),
              icon: Icons.badge_outlined,
              title: 'بيانات المستخدم',
              subtitle: 'الاسم والعنوان والشعار والتوقيع والختم',
              onTap: () => openSettingsPage(
                context,
                UserProfilePage(application: application),
              ),
            ),
            SettingsTile(
              key: const Key('settings-general'),
              icon: Icons.tune,
              title: 'الإعدادات العامة',
              subtitle: 'المظهر والتاريخ والأرصدة والأمان',
              onTap: () => openSettingsPage(
                context,
                GeneralSettingsPage(application: application),
              ),
            ),
            SettingsTile(
              key: const Key('settings-categories'),
              icon: Icons.category_outlined,
              title: 'التصنيفات',
              subtitle: 'إضافة وتعديل وتفعيل وأرشفة وترتيب',
              onTap: () => openSettingsPageInTab(
                context,
                BookCategoryManagementPage(book: application.book),
              ),
            ),
            SettingsTile(
              key: const Key('settings-currencies'),
              icon: Icons.payments_outlined,
              title: 'العملات',
              subtitle: 'الاسم والرمز والمنازل العشرية والعملة الأساسية',
              onTap: () => openSettingsPage(
                context,
                CurrencyManagementPage(application: application),
              ),
            ),
            SettingsTile(
              key: const Key('settings-backup'),
              icon: Icons.backup_outlined,
              title: 'النسخ الاحتياطي',
              subtitle: 'إنشاء نسخة مشفرة واستعادتها ومشاركتها',
              onTap: () => openSettingsPage(
                context,
                BackupSettingsPage(application: application),
              ),
            ),
          ],
        ),
        SettingsGroup(
          title: 'أدوات',
          children: [
            SettingsTile(
              key: const Key('settings-audit'),
              icon: Icons.history,
              title: 'سجل التعديلات',
              subtitle: 'كل إضافة وتعديل وحذف مسجّل بالتاريخ والوقت',
              onTap: () => openSettingsPageInTab(
                context,
                BookAuditLogPage(book: application.book),
              ),
            ),
            SettingsTile(
              key: const Key('settings-archive'),
              icon: Icons.inventory_2_outlined,
              title: 'الأرشيف',
              subtitle: 'التصنيفات والحسابات المؤرشفة واسترجاعها',
              onTap: () => openSettingsPageInTab(
                context,
                BookArchivePage(book: application.book),
              ),
            ),
          ],
        ),
        SettingsGroup(
          title: 'الدعم والمعلومات',
          children: [
            SettingsTile(
              key: const Key('settings-contact'),
              icon: Icons.support_agent,
              title: 'تواصل معنا',
              subtitle: 'الدعم الفني: واتساب، اتصال، بريد، الموقع',
              onTap: () => openSettingsPage(context, const ContactUsPage()),
            ),
            SettingsTile(
              key: const Key('settings-privacy'),
              icon: Icons.privacy_tip_outlined,
              title: 'سياسة الخصوصية',
              subtitle: 'ما يحفظه التطبيق وكيف يحميه',
              onTap: () => openSettingsPage(context, const PrivacyPolicyPage()),
            ),
          ],
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

/// Who the reports are issued by, at a glance.
class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.profile});

  final UserProfile profile;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final name = profile.displayName;
    return JibiSoftCard(
      key: const Key('settings-profile-card'),
      child: Row(
        children: [
          if (profile.logo != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Image.memory(
                profile.logo!,
                width: 52,
                height: 52,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox(width: 52, height: 52),
              ),
            )
          else
            JibiIconBubble(
              icon: Icons.person_outline,
              tint: primary.withValues(alpha: 0.12),
              foreground: primary,
              size: 52,
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name ?? 'لم تُدخل بياناتك بعد',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  name == null
                      ? 'أضف اسمك وشعارك ليظهرا في التقارير.'
                      : 'تظهر هذه البيانات في التقارير و PDF.',
                  style: TextStyle(fontSize: 12, color: context.jibiMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
