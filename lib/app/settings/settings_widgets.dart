import 'package:flutter/material.dart';

import '../../core/errors/app_exception.dart';
import '../../core/models/models.dart';
import '../../shared/widgets/jibi_design.dart';
import '../../shared/widgets/jibi_feedback.dart';
import '../jibi_app_shell.dart';
import '../jibi_application.dart';

/// Saves [settings]; on failure tells the user why and returns false.
Future<bool> saveSettingsOrShow(
  BuildContext context,
  JibiApplication application,
  AppSettings settings,
) async {
  try {
    await application.saveSettings(settings);
    return true;
  } on AppException catch (error) {
    if (context.mounted) showJibiMessage(context, error.userMessage);
  } on Object {
    if (context.mounted) showJibiMessage(context, 'تعذر حفظ الإعدادات.');
  }
  return false;
}

/// Opens a settings screen full screen, without the bottom bar and its "+"
/// button (which would sit over the save buttons and the forms).
Future<void> openSettingsPage(BuildContext context, Widget page) =>
    pushFormPage<void>(context, page);

/// Opens a settings screen inside the accounts tab so the bottom bar stays
/// (the category management screen of the design).
Future<void> openSettingsPageInTab(BuildContext context, Widget page) =>
    pushShellPage<void>(context, page);

/// A titled block of settings rows on a card.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({required this.children, this.title, super.key});

  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 4, bottom: 8),
            child: Text(
              title!,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: context.jibiMuted,
              ),
            ),
          ),
        JibiSoftCard(
          padding: const EdgeInsetsDirectional.fromSTEB(14, 6, 14, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var index = 0; index < children.length; index++) ...[
                if (index > 0)
                  Divider(
                    height: 1,
                    thickness: 0.6,
                    color: Theme.of(context).dividerColor.withValues(alpha: 0.5),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: children[index],
                ),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

/// A settings row: icon bubble, title, subtitle and a chevron.
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.badge,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final String? badge;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: onTap,
      leading: JibiIconBubble(
        icon: icon,
        tint: primary.withValues(alpha: 0.12),
        foreground: primary,
        size: 42,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
            ),
          ),
          if (badge != null) ...[
            const SizedBox(width: 6),
            JibiBadge(
              badge!,
              background: primary.withValues(alpha: 0.1),
              foreground: primary,
            ),
          ],
        ],
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: context.jibiMuted),
            ),
      trailing: Icon(Icons.chevron_left, color: context.jibiMuted),
    );
  }
}
