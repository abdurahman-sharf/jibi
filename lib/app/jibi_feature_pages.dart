import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/errors/app_exception.dart';
import '../core/models/models.dart';
import '../shared/widgets/external_activity_scope.dart';
import '../shared/widgets/jibi_design.dart';
import '../core/storage/document_source_picker.dart';
import '../core/storage/secure_file_storage.dart';
import '../core/storage/file_sharing.dart';
import '../features/credentials/credentials.dart';
import '../features/documents/documents_controller.dart';
import '../features/documents/models/document_draft.dart';
import '../shared/widgets/jibi_feedback.dart';
import '../shared/widgets/jibi_page.dart';
import '../shared/widgets/pin_prompt.dart';
import 'book/book_category_page.dart' show openBookAccount;
import 'jibi_app_shell.dart';
import 'jibi_application.dart';
import 'document_preview.dart';

enum VaultSegment { credentials, documents }

/// كلمات المرور tab: opens the redesigned vault on the passwords segment.
class CredentialsPage extends StatelessWidget {
  const CredentialsPage({
    required this.controller,
    this.documents,
    this.settings,
    super.key,
  });

  final CredentialVaultController controller;
  final DocumentsController? documents;
  final AppSettings? settings;

  @override
  Widget build(BuildContext context) => _VaultPage(
    credentials: controller,
    documents: documents,
    settings: settings,
    initialSegment: VaultSegment.credentials,
  );
}

/// Redesigned vault: dark security status card, segmented control between
/// passwords and documents, and rich cards. Sensitive values stay masked in
/// the list; opening a card goes through re-authentication in its details
/// page, and copying triggers the controller's secure clipboard flow.
class _VaultPage extends StatefulWidget {
  const _VaultPage({
    required this.credentials,
    required this.documents,
    required this.initialSegment,
    this.settings,
  });

  final CredentialVaultController? credentials;
  final DocumentsController? documents;
  final VaultSegment initialSegment;
  final AppSettings? settings;

  @override
  State<_VaultPage> createState() => _VaultPageState();
}

class _VaultPageState extends State<_VaultPage> {
  late VaultSegment _segment = widget.initialSegment;
  bool _favoritesOnly = false;

  /// One live stream each, only used to show the counts on the segment bar.
  late final Stream<List<Credential>>? _credentialCounts = widget.credentials
      ?.watch();
  late final Stream<List<Document>>? _documentCounts = widget.documents
      ?.watchDocuments();

  @override
  Widget build(BuildContext context) {
    final credentials = widget.credentials;
    final documents = widget.documents;
    if (credentials == null && documents == null) {
      return const JibiEmptyState(
        title: 'الخزنة غير مهيأة',
        message: 'أعد تشغيل التطبيق لتهيئة الخزنة المشفرة.',
      );
    }
    return JibiPage(
      padding: const EdgeInsetsDirectional.fromSTEB(20, 8, 20, 120),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.settings != null) ...[
            _SecurityStatusCard(settings: widget.settings!),
            const SizedBox(height: 16),
          ],
          StreamBuilder<List<Credential>>(
            stream: _credentialCounts,
            builder: (context, credentialSnapshot) =>
                StreamBuilder<List<Document>>(
                  stream: _documentCounts,
                  builder: (context, documentSnapshot) => _VaultSegmentBar(
                    segment: _segment,
                    showCredentials: credentials != null,
                    showDocuments: documents != null,
                    credentialCount: credentialSnapshot.data?.length,
                    documentCount: documentSnapshot.data?.length,
                    onSelect: (segment) => setState(() {
                      _segment = segment;
                      _favoritesOnly = false;
                    }),
                  ),
                ),
          ),
          const SizedBox(height: 14),
          if (_segment == VaultSegment.credentials)
            _CredentialsList(
              controller: credentials,
              favoritesOnly: _favoritesOnly,
              onToggleFavorites: credentials == null
                  ? null
                  : () => setState(() => _favoritesOnly = !_favoritesOnly),
            )
          else
            _DocumentsList(controller: documents),
        ],
      ),
    );
  }
}

/// Dark green security status panel at the top of the vault.
/// Security summary derived from the real settings. Encrypted local storage
/// and the PIN are always on (half the score); screenshot protection and a
/// short auto-lock each add a quarter.
class _SecurityStatusCard extends StatelessWidget {
  const _SecurityStatusCard({required this.settings});

  final AppSettings settings;

  static int score(AppSettings settings) {
    var value = 50;
    if (settings.screenshotProtectionEnabled) value += 25;
    if (settings.autoLockDuration != AutoLockDuration.fifteenMinutes) {
      value += 25;
    }
    return value;
  }

  static String lockLabel(AutoLockDuration duration) => switch (duration) {
    AutoLockDuration.immediate => 'قفل فوري عند الخروج',
    AutoLockDuration.oneMinute => 'قفل بعد دقيقة',
    AutoLockDuration.fiveMinutes => 'قفل بعد 5 دقائق',
    AutoLockDuration.fifteenMinutes => 'قفل بعد 15 دقيقة',
  };

  @override
  Widget build(BuildContext context) {
    final value = score(settings);
    final title = switch (value) {
      >= 100 => 'حالة الأمان ممتازة',
      >= 75 => 'حالة الأمان جيدة',
      _ => 'حالة الأمان تحتاج تحسينًا',
    };
    return JibiDarkPanel(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: const Icon(
                  Icons.shield_outlined,
                  color: Colors.white,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 15.5,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          width: 7,
                          height: 7,
                          decoration: const BoxDecoration(
                            color: JibiColors.gold,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'تشفير AES-256 محلي مع حماية برمز PIN',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                '$value%',
                style: const TextStyle(
                  color: JibiColors.gold,
                  fontWeight: FontWeight.w900,
                  fontSize: 22,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          JibiProgressBar(value: value / 100),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _SecurityChip(
                  icon: Icons.lock_outline,
                  label: lockLabel(settings.autoLockDuration),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _SecurityChip(
                  icon: settings.screenshotProtectionEnabled
                      ? Icons.screenshot_monitor_outlined
                      : Icons.no_photography_outlined,
                  label: settings.screenshotProtectionEnabled
                      ? 'لقطات الشاشة محظورة'
                      : 'لقطات الشاشة مسموحة',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SecurityChip extends StatelessWidget {
  const _SecurityChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        Icon(icon, size: 16, color: JibiColors.goldSoft),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
  );
}

/// Segmented control between كلمات المرور and المستندات الحساسة.
class _VaultSegmentBar extends StatelessWidget {
  const _VaultSegmentBar({
    required this.segment,
    required this.showCredentials,
    required this.showDocuments,
    required this.credentialCount,
    required this.documentCount,
    required this.onSelect,
  });

  final VaultSegment segment;
  final bool showCredentials;
  final bool showDocuments;

  /// Null while the count is still loading (the badge is then hidden).
  final int? credentialCount;
  final int? documentCount;
  final ValueChanged<VaultSegment> onSelect;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(5),
    decoration: BoxDecoration(
      color: JibiColors.mintCard.withValues(alpha: 0.7),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      children: [
        if (showCredentials)
          Expanded(
            child: _SegmentCell(
              selected: segment == VaultSegment.credentials,
              icon: Icons.key_outlined,
              label: 'كلمات المرور',
              count: credentialCount,
              onTap: () => onSelect(VaultSegment.credentials),
            ),
          ),
        if (showCredentials && showDocuments) const SizedBox(width: 6),
        if (showDocuments)
          Expanded(
            child: _SegmentCell(
              selected: segment == VaultSegment.documents,
              icon: Icons.folder_shared_outlined,
              label: 'المستندات الحساسة',
              count: documentCount,
              onTap: () => onSelect(VaultSegment.documents),
            ),
          ),
      ],
    ),
  );
}

class _SegmentCell extends StatelessWidget {
  const _SegmentCell({
    required this.selected,
    required this.icon,
    required this.label,
    required this.count,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final int? count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(12),
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 8),
      decoration: BoxDecoration(
        color: selected ? JibiColors.deepGreen : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 17,
            color: selected ? Colors.white : JibiColors.deepGreen,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: selected ? Colors.white : JibiColors.onTintInk,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (count != null) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
              decoration: BoxDecoration(
                color: selected
                    ? Colors.white.withValues(alpha: 0.2)
                    : JibiColors.deepGreen.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '($count)',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  color: selected ? Colors.white : JibiColors.deepGreen,
                ),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

/// Passwords list with favorites chip and rich credential cards.
class _CredentialsList extends StatelessWidget {
  const _CredentialsList({
    required this.controller,
    required this.favoritesOnly,
    required this.onToggleFavorites,
  });

  final CredentialVaultController? controller;
  final bool favoritesOnly;
  final VoidCallback? onToggleFavorites;

  @override
  Widget build(BuildContext context) {
    final vault = controller;
    if (vault == null) {
      return const SizedBox.shrink();
    }
    return StreamBuilder<List<Credential>>(
      stream: vault.watch(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const JibiErrorState(message: 'تعذر تحميل خزنة كلمات المرور.');
        }
        if (!snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: LinearProgressIndicator(minHeight: 3),
          );
        }
        final credentials = snapshot.data!;
        final visible = favoritesOnly
            ? credentials.where((c) => c.isFavorite).toList()
            : credentials;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _VaultChip(
                  label: 'الكل (${credentials.length})',
                  selected: !favoritesOnly,
                  onTap: onToggleFavorites == null
                      ? null
                      : favoritesOnly
                      ? () => onToggleFavorites!()
                      : null,
                ),
                const SizedBox(width: 8),
                _VaultChip(
                  label:
                      'المفضلة (${credentials.where((c) => c.isFavorite).length})',
                  selected: favoritesOnly,
                  onTap: onToggleFavorites == null
                      ? null
                      : !favoritesOnly
                      ? () => onToggleFavorites!()
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (visible.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 22),
                child: Column(
                  children: [
                    Icon(
                      Icons.key_off_outlined,
                      size: 42,
                      color: context.jibiMuted,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      favoritesOnly
                          ? 'لا توجد عناصر مفضلة بعد.'
                          : 'خزنتك فارغة. أضف بيانات دخولك الأولى.',
                      style: TextStyle(color: context.jibiMuted),
                    ),
                  ],
                ),
              )
            else
              for (final credential in visible)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _CredentialCard(
                    credential: credential,
                    controller: vault,
                  ),
                ),
          ],
        );
      },
    );
  }
}

/// Vault card for one credential. Values stay masked; reveal and copy go
/// through re-authentication.
class _CredentialCard extends StatelessWidget {
  const _CredentialCard({required this.credential, required this.controller});

  final Credential credential;
  final CredentialVaultController controller;

  void _openDetails(BuildContext context) {
    pushShellPage<void>(
      context,
      CredentialDetailsPage(credential: credential, controller: controller),
    );
  }

  Future<void> _copy(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    var copied = false;
    try {
      copied = await controller.copyPassword(credential);
    } on Object {
      copied = false;
    }
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          copied
              ? 'تم نسخ كلمة المرور. تُحذف من الحافظة تلقائياً بعد ${controller.clipboardClearAfter.inSeconds} ثانية.'
              : 'تعذر النسخ. تحقق من هويتك ثم أعد المحاولة.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => JibiSoftCard(
    onTap: () => _openDetails(context),
    padding: const EdgeInsets.all(14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            JibiIconBubble(
              icon: Icons.person_outline,
              tint: JibiColors.mintCard,
              foreground: JibiColors.deepGreen,
              size: 46,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          credential.title,
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                            color: context.jibiInk,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (credential.isFavorite) ...[
                        const SizedBox(width: 6),
                        JibiBadge(
                          'مفضلة',
                          background: JibiColors.goldSoft.withValues(
                            alpha: 0.4,
                          ),
                          foreground: const Color(0xFF8A6A14),
                          icon: Icons.star_outline,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    credential.url ?? 'بيانات دخول مشفرة محلياً',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: context.jibiMuted,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'فتح التفاصيل',
              icon: Icon(Icons.more_vert, color: context.jibiMuted),
              onPressed: () => _openDetails(context),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 6, 4),
          decoration: BoxDecoration(
            color: JibiColors.mintCard.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.vpn_key_outlined,
                size: 17,
                color: JibiColors.onTintMuted,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Directionality(
                  textDirection: TextDirection.ltr,
                  child: Text(
                    '••••••••••••',
                    style: TextStyle(
                      letterSpacing: 2,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: JibiColors.onTintInk,
                    ),
                  ),
                ),
              ),
              JibiBadge(
                'مشفرة AES-256',
                background: JibiColors.deepGreen.withValues(alpha: 0.08),
                foreground: JibiColors.deepGreen,
              ),
              IconButton(
                tooltip: 'كشف كلمة المرور',
                icon: const Icon(Icons.visibility_outlined, size: 19),
                color: JibiColors.deepGreen,
                onPressed: () => _openDetails(context),
              ),
              IconButton(
                tooltip: 'نسخ كلمة المرور',
                icon: const Icon(Icons.copy_outlined, size: 19),
                color: JibiColors.deepGreen,
                onPressed: () => unawaited(_copy(context)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Icon(Icons.update_outlined, size: 14, color: context.jibiMuted),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                'آخر تحديث: ${jibiRelativeTimeAr(credential.updatedAt)}',
                style: TextStyle(fontSize: 11, color: context.jibiMuted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            JibiBadge(
              'مشفّرة محلياً',
              background: JibiColors.mintCard,
              foreground: context.jibiMuted,
              icon: Icons.lock_outline,
            ),
          ],
        ),
      ],
    ),
  );
}

/// Documents list of the vault.
class _DocumentsList extends StatelessWidget {
  const _DocumentsList({required this.controller});

  final DocumentsController? controller;

  @override
  Widget build(BuildContext context) {
    final documentsController = controller;
    if (documentsController == null) {
      return const SizedBox.shrink();
    }
    return StreamBuilder<List<Document>>(
      stream: documentsController.watchDocuments(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const JibiErrorState(message: 'تعذر تحميل المستندات.');
        }
        if (!snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: LinearProgressIndicator(minHeight: 3),
          );
        }
        final documents = snapshot.data!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _VaultChip(label: 'الكل (${documents.length})', selected: true),
              ],
            ),
            const SizedBox(height: 12),
            if (documents.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 22),
                child: Column(
                  children: [
                    Icon(
                      Icons.folder_off_outlined,
                      size: 42,
                      color: context.jibiMuted,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'لا توجد مستندات. أضف أول مستند مشفر.',
                      style: TextStyle(color: context.jibiMuted),
                    ),
                  ],
                ),
              )
            else
              for (final document in documents)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _DocumentCard(
                    document: document,
                    controller: documentsController,
                  ),
                ),
          ],
        );
      },
    );
  }
}

/// Vault card for one encrypted document.
class _DocumentCard extends StatelessWidget {
  const _DocumentCard({required this.document, required this.controller});

  final Document document;
  final DocumentsController controller;

  @override
  Widget build(BuildContext context) => JibiSoftCard(
    onTap: () => pushShellPage<void>(
      context,
      DocumentDetailsPage(document: document, controller: controller),
    ),
    padding: const EdgeInsets.all(14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _DocumentTypeIcon(document: document, controller: controller),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          document.title,
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                            color: context.jibiInk,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      JibiBadge(
                        'مستند مشفر',
                        background: JibiColors.deepGreen.withValues(alpha: 0.1),
                        foreground: JibiColors.deepGreen,
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    document.expiryDate == null
                        ? 'بدون تاريخ انتهاء'
                        : 'صالح حتى: '
                              '${document.expiryDate!.day}/'
                              '${document.expiryDate!.month}/'
                              '${document.expiryDate!.year}',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: context.jibiMuted,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_left, color: context.jibiMuted),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Icon(Icons.update_outlined, size: 14, color: context.jibiMuted),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                'آخر تحديث: ${jibiRelativeTimeAr(document.updatedAt)}',
                style: TextStyle(fontSize: 11, color: context.jibiMuted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            JibiBadge(
              'تشفير كامل',
              background: JibiColors.mintCard,
              foreground: JibiColors.deepGreen,
              icon: Icons.lock_outline,
            ),
          ],
        ),
      ],
    ),
  );
}

/// Icon that follows the attached files: an image, a PDF, or a generic
/// document when it has no files (or mixed types).
class _DocumentTypeIcon extends StatefulWidget {
  const _DocumentTypeIcon({required this.document, required this.controller});

  final Document document;
  final DocumentsController controller;

  @override
  State<_DocumentTypeIcon> createState() => _DocumentTypeIconState();
}

class _DocumentTypeIconState extends State<_DocumentTypeIcon> {
  late Future<List<DocumentFile>> _files = widget.controller.listFiles(
    widget.document.id,
  );

  @override
  void didUpdateWidget(covariant _DocumentTypeIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.document.id != widget.document.id ||
        oldWidget.document.updatedAt != widget.document.updatedAt) {
      _files = widget.controller.listFiles(widget.document.id);
    }
  }

  static IconData _iconFor(List<DocumentFile> files) {
    if (files.isEmpty) return Icons.description_outlined;
    if (files.every((file) => file.mimeType.startsWith('image/'))) {
      return Icons.image_outlined;
    }
    if (files.every((file) => file.mimeType == 'application/pdf')) {
      return Icons.picture_as_pdf_outlined;
    }
    return Icons.folder_copy_outlined;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<DocumentFile>>(
    future: _files,
    builder: (context, snapshot) => JibiIconBubble(
      icon: _iconFor(snapshot.data ?? const <DocumentFile>[]),
      tint: const Color(0xFFE4EEF8),
      foreground: const Color(0xFF2E5E8C),
      size: 46,
    ),
  );
}

class _VaultChip extends StatelessWidget {
  const _VaultChip({required this.label, required this.selected, this.onTap});

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final unselected =
        context.jibiIsDark ? const Color(0xFF22302B) : Colors.white;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? JibiColors.deepGreen : unselected,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: selected ? Colors.white : context.jibiInk,
          ),
        ),
      ),
    );
  }
}

class CredentialFormPage extends StatefulWidget {
  const CredentialFormPage({required this.controller, this.details, super.key});

  final CredentialVaultController controller;
  final CredentialDetails? details;

  @override
  State<CredentialFormPage> createState() => _CredentialFormPageState();
}

class _CredentialFormPageState extends State<CredentialFormPage> {
  final _title = TextEditingController();
  final _username = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _url = TextEditingController();
  final _notes = TextEditingController();
  bool _favorite = false;
  bool _saving = false;
  bool _showPassword = false;

  void _generatePassword() {
    try {
      setState(() {
        _password.text = PasswordGenerator().generate();
        // Show what was generated so it can be read before saving.
        _showPassword = true;
      });
    } on AppException catch (error) {
      _showError(context, error.userMessage);
    }
  }

  @override
  void initState() {
    super.initState();
    final details = widget.details;
    if (details == null) return;
    _title.text = details.credential.title;
    _username.text = details.username;
    _email.text = details.email;
    _password.text = details.password;
    _url.text = details.credential.url ?? '';
    _notes.text = details.notes;
    _favorite = details.credential.isFavorite;
  }

  @override
  void dispose() {
    _title.dispose();
    _username.dispose();
    _email.dispose();
    _password.dispose();
    _url.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final input = CredentialInput(
        title: _title.text,
        username: _username.text,
        email: _email.text,
        password: _password.text,
        notes: _notes.text,
        url: _optional(_url.text),
        isFavorite: _favorite,
        categoryId: widget.details?.credential.categoryId,
      );
      final existing = widget.details?.credential;
      if (existing == null) {
        await widget.controller.create(input);
      } else {
        await widget.controller.update(existing: existing, input: input);
      }
      _password.clear();
      if (mounted) {
        Navigator.of(context).pop();
      }
    } on AppException catch (error) {
      if (mounted) {
        _showError(context, error.userMessage);
      }
    } on Object {
      if (mounted) {
        _showError(context, 'تعذر حفظ بيانات الدخول.');
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.details == null ? 'إضافة كلمة مرور' : 'تعديل بيانات الدخول',
      ),
    ),
    body: JibiPage(
      child: Column(
        children: [
          TextField(
            controller: _title,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'الخدمة *'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _username,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'اسم المستخدم'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'البريد الإلكتروني'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: !_showPassword,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'كلمة المرور',
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: _showPassword
                        ? 'إخفاء كلمة المرور'
                        : 'إظهار كلمة المرور',
                    icon: Icon(
                      _showPassword
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                    onPressed: () =>
                        setState(() => _showPassword = !_showPassword),
                  ),
                  IconButton(
                    tooltip: 'توليد كلمة مرور قوية',
                    icon: const Icon(Icons.autorenew),
                    onPressed: _saving ? null : _generatePassword,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: 'رابط الموقع'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _notes,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'ملاحظات'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('مفضلة'),
            value: _favorite,
            onChanged: _saving
                ? null
                : (value) => setState(() => _favorite = value),
          ),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'جارٍ الحفظ…' : 'حفظ'),
            ),
          ),
        ],
      ),
    ),
  );
}

class CredentialDetailsPage extends StatefulWidget {
  const CredentialDetailsPage({
    required this.credential,
    required this.controller,
    super.key,
  });

  final Credential credential;
  final CredentialVaultController controller;

  @override
  State<CredentialDetailsPage> createState() => _CredentialDetailsPageState();
}

class _CredentialDetailsPageState extends State<CredentialDetailsPage> {
  late Credential _credential = widget.credential;
  CredentialDetails? _details;
  bool _loading = false;

  Future<void> _edit() async {
    setState(() => _loading = true);
    try {
      final details = await widget.controller.read(_credential.id);
      if (!mounted) return;
      if (details == null) {
        _showError(context, 'تعذر التحقق من هويتك لتعديل البيانات.');
        return;
      }
      setState(() => _details = null);
      await pushFormPage<void>(
        context,
        CredentialFormPage(controller: widget.controller, details: details),
      );
      final updated = await widget.controller.repository.findCredential(
        _credential.id,
      );
      if (mounted && updated != null) setState(() => _credential = updated);
    } on Object {
      if (mounted) _showError(context, 'تعذر فتح بيانات الدخول للتعديل.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _reveal() async {
    setState(() => _loading = true);
    try {
      final details = await widget.controller.read(widget.credential.id);
      if (!mounted) {
        return;
      }
      if (details == null) {
        _showError(context, 'تعذر التحقق من هويتك لعرض البيانات.');
      } else {
        setState(() => _details = details);
      }
    } on AppException catch (error) {
      if (mounted) {
        _showError(context, error.userMessage);
      }
    } on Object {
      if (mounted) {
        _showError(context, 'تعذر عرض البيانات.');
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _copyPassword() async {
    try {
      final copied = await widget.controller.copyPassword(_credential);
      if (!mounted) {
        return;
      }
      showJibiMessage(
        context,
        copied
            ? 'تم نسخ كلمة المرور. تُحذف من الحافظة بعد ${widget.controller.clipboardClearAfter.inSeconds} ثانية.'
            : 'تعذر التحقق من هويتك للنسخ.',
      );
    } on AppException catch (error) {
      if (mounted) {
        _showError(context, error.userMessage);
      }
    } on Object {
      if (mounted) {
        _showError(context, 'تعذر نسخ كلمة المرور.');
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_credential.title),
      actions: [
        IconButton(
          tooltip: 'تعديل بيانات الدخول',
          icon: const Icon(Icons.edit_outlined),
          onPressed: _loading ? null : _edit,
        ),
        IconButton(
          tooltip: 'حذف',
          icon: const Icon(Icons.delete_outline),
          onPressed: _delete,
        ),
      ],
    ),
    body: JibiPage(
      child: _details == null
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('الحقول الحساسة مخفية حتى إعادة التحقق من الهوية.'),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _loading ? null : _reveal,
                  icon: const Icon(Icons.visibility_outlined),
                  label: Text(_loading ? 'جارٍ التحقق…' : 'عرض البيانات'),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SensitiveRow(label: 'اسم المستخدم', value: _details!.username),
                _SensitiveRow(label: 'البريد', value: _details!.email),
                _SensitiveRow(
                  label: 'كلمة المرور',
                  value: _details!.password,
                  secret: true,
                ),
                if (_credential.url != null)
                  _SensitiveRow(label: 'الموقع', value: _credential.url!),
                _SensitiveRow(label: 'ملاحظات', value: _details!.notes),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _copyPassword,
                  icon: const Icon(Icons.copy_outlined),
                  label: const Text('نسخ كلمة المرور'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _copyUsername,
                  icon: const Icon(Icons.person_outline),
                  label: const Text('نسخ اسم المستخدم'),
                ),
              ],
            ),
    ),
  );

  Future<void> _copyUsername() async {
    try {
      final copied = await widget.controller.copyUsername(_credential);
      if (!mounted) return;
      showJibiMessage(
        context,
        copied
            ? 'تم نسخ اسم المستخدم. يُحذف من الحافظة بعد ${widget.controller.clipboardClearAfter.inSeconds} ثانية.'
            : 'تعذر التحقق من هويتك للنسخ.',
      );
    } on AppException catch (error) {
      if (mounted) _showError(context, error.userMessage);
    } on Object {
      if (mounted) _showError(context, 'تعذر نسخ اسم المستخدم.');
    }
  }

  Future<void> _delete() async {
    final confirmed = await JibiConfirmationDialog.show(
      context,
      title: 'حذف بيانات الدخول',
      message: 'هل تريد حذف بيانات ${widget.credential.title}؟',
      confirmLabel: 'حذف',
      isDestructive: true,
    );
    if (confirmed != true) {
      return;
    }
    try {
      await widget.controller.delete(widget.credential.id);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } on AppException catch (error) {
      if (mounted) {
        _showError(context, error.userMessage);
      }
    } on Object {
      if (mounted) {
        _showError(context, 'تعذر حذف بيانات الدخول.');
      }
    }
  }
}

/// One decrypted field. A [secret] row stays masked until the eye is tapped,
/// so shoulder-surfers do not read the password the moment the page opens.
class _SensitiveRow extends StatefulWidget {
  const _SensitiveRow({
    required this.label,
    required this.value,
    this.secret = false,
  });

  final String label;
  final String value;
  final bool secret;

  @override
  State<_SensitiveRow> createState() => _SensitiveRowState();
}

class _SensitiveRowState extends State<_SensitiveRow> {
  bool _visible = false;

  @override
  Widget build(BuildContext context) {
    final masked = widget.secret && !_visible;
    return ListTile(
      title: Text(widget.label),
      subtitle: masked
          ? const Text('••••••••••••')
          : SelectableText(widget.value),
      trailing: widget.secret
          ? IconButton(
              tooltip: _visible ? 'إخفاء' : 'إظهار',
              icon: Icon(
                _visible
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
              ),
              onPressed: () => setState(() => _visible = !_visible),
            )
          : null,
    );
  }
}

/// Searches only fields that are intentionally searchable. Vault passwords and
/// encrypted document metadata are never decrypted or indexed for search.
class GlobalSearchPage extends StatefulWidget {
  const GlobalSearchPage({required this.application, super.key});

  final JibiApplication application;

  @override
  State<GlobalSearchPage> createState() => _GlobalSearchPageState();
}

class _GlobalSearchPageState extends State<GlobalSearchPage> {
  final _query = TextEditingController();

  @override
  void initState() {
    super.initState();
    _query.addListener(_refresh);
  }

  @override
  void dispose() {
    _query
      ..removeListener(_refresh)
      ..dispose();
    super.dispose();
  }

  void _refresh() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final query = _query.text;
    return Scaffold(
      appBar: AppBar(title: const Text('بحث')),
      body: JibiPage(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _query,
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'ابحث في الحسابات والخدمات والمستندات',
              ),
            ),
            const SizedBox(height: 24),
            _SearchSection<AccountSummary>(
              title: 'الحسابات',
              queryKey: query,
              createStream: () =>
                  widget.application.book.accounts.watchSearch(query),
              itemBuilder: (summary) => ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(summary.account.name),
                subtitle: summary.currencies.isEmpty
                    ? null
                    : Text(summary.currencyCodes.join(' · ')),
                onTap: () => openBookAccount(
                  context,
                  widget.application.book,
                  summary.account.id,
                ),
              ),
            ),
            _SearchSection<Credential>(
              title: 'كلمات المرور',
              queryKey: query,
              createStream: () =>
                  widget.application.credentials.watch(query: query),
              itemBuilder: (credential) => ListTile(
                leading: const Icon(Icons.key_outlined),
                title: Text(credential.title),
                subtitle: const Text('اسم الخدمة فقط'),
                onTap: () => pushShellPage<void>(
                  context,
                  CredentialDetailsPage(
                    credential: credential,
                    controller: widget.application.credentials,
                  ),
                ),
              ),
            ),
            _SearchSection<Document>(
              title: 'المستندات',
              queryKey: query,
              createStream: () =>
                  widget.application.documents.watchDocuments(query: query),
              itemBuilder: (document) => ListTile(
                leading: const Icon(Icons.description_outlined),
                title: Text(document.title),
                onTap: () => pushShellPage<void>(
                  context,
                  DocumentDetailsPage(
                    document: document,
                    controller: widget.application.documents,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Keeps one live stream per query so repeated rebuilds (every keystroke)
/// never resubscribe or flash empty results.
class _SearchSection<T> extends StatefulWidget {
  const _SearchSection({
    required this.title,
    required this.queryKey,
    required this.createStream,
    required this.itemBuilder,
  });

  final String title;
  final String queryKey;
  final Stream<List<T>> Function() createStream;
  final Widget Function(T value) itemBuilder;

  @override
  State<_SearchSection<T>> createState() => _SearchSectionState<T>();
}

class _SearchSectionState<T> extends State<_SearchSection<T>> {
  late String _queryKey = widget.queryKey;
  late Stream<List<T>> _stream = widget.createStream();

  @override
  void didUpdateWidget(covariant _SearchSection<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.queryKey != _queryKey) {
      _queryKey = widget.queryKey;
      _stream = widget.createStream();
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<List<T>>(
    stream: _stream,
    builder: (context, snapshot) {
      final values = snapshot.data ?? <T>[];
      return JibiSection(
        title: widget.title,
        padding: const EdgeInsets.only(bottom: 20),
        child: snapshot.hasError
            ? const Text('تعذر تحميل النتائج. حاول مرة أخرى.')
            : !snapshot.hasData
            ? const LinearProgressIndicator(minHeight: 3)
            : values.isEmpty
            ? const Text('لا توجد نتائج')
            : Column(
                children: [
                  for (final value in values) widget.itemBuilder(value),
                ],
              ),
      );
    },
  );
}

/// المستندات tab: opens the same vault on the documents segment.
class DocumentsPage extends StatelessWidget {
  const DocumentsPage({
    required this.controller,
    this.credentials,
    this.settings,
    super.key,
  });

  final DocumentsController controller;
  final CredentialVaultController? credentials;
  final AppSettings? settings;

  @override
  Widget build(BuildContext context) => _VaultPage(
    credentials: credentials,
    documents: controller,
    settings: settings,
    initialSegment: VaultSegment.documents,
  );
}

class DocumentFormPage extends StatefulWidget {
  const DocumentFormPage({
    required this.controller,
    this.document,
    this.details,
    this.picker = const AndroidDocumentSourcePicker(),
    super.key,
  });

  final DocumentsController controller;
  final Document? document;
  final Map<String, String>? details;
  final DocumentSourcePicker picker;

  @override
  State<DocumentFormPage> createState() => _DocumentFormPageState();
}

class _DocumentFormPageState extends State<DocumentFormPage> {
  DateTime? _issueDate;
  DateTime? _expiryDate;
  Widget _dateField(
    String label,
    DateTime? value,
    ValueChanged<DateTime?> update,
  ) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(label),
    subtitle: Text(
      value == null ? 'غير محدد' : '${value.year}/${value.month}/${value.day}',
    ),
    leading: const Icon(Icons.calendar_month_outlined),
    trailing: value == null
        ? null
        : IconButton(
            tooltip: 'مسح $label',
            onPressed: _saving ? null : () => setState(() => update(null)),
            icon: const Icon(Icons.close),
          ),
    onTap: _saving
        ? null
        : () async {
            final selected = await showDatePicker(
              context: context,
              initialDate: value ?? DateTime.now(),
              firstDate: DateTime(1900),
              lastDate: DateTime(2200),
            );
            if (mounted && selected != null) setState(() => update(selected));
          },
  );
  final _selectedFiles = <FileImportRequest>[];
  bool _picking = false;

  Future<void> _pickFile() => _addSource(
    widget.picker.pickFile,
    'تعذر اختيار الملف. أعد المحاولة.',
  );

  Future<void> _captureImage() => _addSource(
    widget.picker.captureImage,
    'تعذر التقاط الصورة. أعد المحاولة.',
  );

  Future<void> _addSource(
    Future<FileImportRequest?> Function() acquire,
    String failureMessage,
  ) async {
    setState(() => _picking = true);
    final runExternal = ExternalActivityScope.of(context);
    try {
      final request = await runExternal(acquire);
      if (request == null) return;
      if (!mounted) {
        await request.sourceFile.delete();
        return;
      }
      setState(() => _selectedFiles.add(request));
    } on AppException catch (error) {
      if (mounted) _showError(context, error.userMessage);
    } on Object {
      if (mounted) _showError(context, failureMessage);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _cleanupSelectedFiles() async {
    for (final request in _selectedFiles) {
      try {
        if (await request.sourceFile.exists()) {
          await request.sourceFile.delete();
        }
      } on FileSystemException {
        // Cache cleanup may be retried by the operating system.
      }
    }
  }

  final _title = TextEditingController();
  final _number = TextEditingController();
  final _issuer = TextEditingController();
  final _notes = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _title.text = widget.document?.title ?? '';
    _number.text = widget.details?['رقم المستند'] ?? '';
    _issuer.text = widget.details?['جهة الإصدار'] ?? '';
    _notes.text = widget.details?['ملاحظات'] ?? '';
    _issueDate = widget.document?.issueDate?.toLocal();
    _expiryDate = widget.document?.expiryDate?.toLocal();
  }

  @override
  void dispose() {
    _title.dispose();
    _number.dispose();
    _issuer.dispose();
    _notes.dispose();
    _cleanupSelectedFiles();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final draft = DocumentDraft(
        title: _title.text,
        documentNumber: _optional(_number.text),
        issuer: _optional(_issuer.text),
        notes: _optional(_notes.text),
        categoryId: widget.document?.categoryId,
        issueDate: _issueDate,
        expiryDate: _expiryDate,
        tagIds: widget.document?.tagIds ?? const [],
      );
      if (widget.document == null) {
        await widget.controller.createWithFiles(draft, _selectedFiles);
        // The files are encrypted now; remove the plaintext copies (camera
        // photos included) immediately rather than waiting for dispose().
        await _cleanupSelectedFiles();
        _selectedFiles.clear();
      } else {
        await widget.controller.updateDocument(widget.document!.id, draft);
      }
      if (mounted) {
        Navigator.of(context).pop();
      }
    } on AppException catch (error) {
      if (mounted) {
        _showError(context, error.userMessage);
      }
    } on Object {
      if (mounted) {
        _showError(context, 'تعذر حفظ المستند.');
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.document == null ? 'إضافة مستند' : 'تعديل المستند'),
    ),
    body: JibiPage(
      child: Column(
        children: [
          TextField(
            controller: _title,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'اسم المستند *'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _number,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'رقم المستند'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _issuer,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'جهة الإصدار'),
          ),
          _dateField(
            'تاريخ الإصدار',
            _issueDate,
            (value) => _issueDate = value,
          ),
          _dateField(
            'تاريخ الانتهاء',
            _expiryDate,
            (value) => _expiryDate = value,
          ),
          if (widget.document == null) ...[
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _saving || _picking ? null : _pickFile,
              icon: const Icon(Icons.upload_file_outlined),
              label: Text(
                _picking ? 'جارٍ اختيار الملف…' : 'إرفاق ملف من الجهاز',
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _saving || _picking ? null : _captureImage,
              icon: const Icon(Icons.photo_camera_outlined),
              label: const Text('التقاط صورة بالكاميرا'),
            ),
            for (final request in _selectedFiles)
              ListTile(
                title: Text(request.sourceFile.uri.pathSegments.last),
                subtitle: Text(request.originalExtension.toUpperCase()),
                trailing: IconButton(
                  tooltip: 'إزالة المرفق المحدد',
                  icon: const Icon(Icons.close),
                  onPressed: _saving
                      ? null
                      : () async {
                          try {
                            if (await request.sourceFile.exists()) {
                              await request.sourceFile.delete();
                            }
                            if (mounted) {
                              setState(() => _selectedFiles.remove(request));
                            }
                          } on Object {
                            if (context.mounted) {
                              _showError(context, 'تعذر إزالة الملف المؤقت.');
                            }
                          }
                        },
                ),
              ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _notes,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'ملاحظات'),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'جارٍ الحفظ…' : 'حفظ'),
            ),
          ),
        ],
      ),
    ),
  );
}

class DocumentDetailsPage extends StatefulWidget {
  const DocumentDetailsPage({
    required this.document,
    required this.controller,
    this.picker = const AndroidDocumentSourcePicker(),
    super.key,
  });

  final Document document;
  final DocumentsController controller;
  final DocumentSourcePicker picker;

  @override
  State<DocumentDetailsPage> createState() => _DocumentDetailsPageState();
}

class _DocumentDetailsPageState extends State<DocumentDetailsPage> {
  late Document _document = widget.document;
  late Future<Map<String, String>> _details = widget.controller.readDetails(
    _document,
  );
  late Future<List<DocumentFile>> _files = widget.controller.listFiles(
    widget.document.id,
  );
  bool _importing = false;

  Future<void> _edit() async {
    setState(() => _importing = true);
    try {
      final current = await widget.controller.findDocument(_document.id);
      if (current == null) return;
      final details = await widget.controller.readDetails(current);
      if (!mounted) return;
      await pushFormPage<void>(
        context,
        DocumentFormPage(
          controller: widget.controller,
          document: current,
          details: details,
        ),
      );
      final updated = await widget.controller.findDocument(_document.id);
      if (mounted && updated != null) {
        setState(() {
          _document = updated;
          _details = widget.controller.readDetails(updated);
        });
      }
    } on Object {
      if (mounted) _showError(context, 'تعذر فتح المستند للتعديل.');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _importFile() => _attach(
    widget.picker.pickFile,
    'تعذر إرفاق الملف.',
  );

  Future<void> _captureImage() => _attach(
    widget.picker.captureImage,
    'تعذر إرفاق الصورة.',
  );

  Future<void> _attach(
    Future<FileImportRequest?> Function() acquire,
    String failureMessage,
  ) async {
    FileImportRequest? request;
    setState(() => _importing = true);
    final runExternal = ExternalActivityScope.of(context);
    try {
      request = await runExternal(acquire);
      if (request == null) {
        return;
      }
      await widget.controller.importFile(
        documentId: widget.document.id,
        request: request,
      );
      if (mounted) {
        setState(
          () => _files = widget.controller.listFiles(widget.document.id),
        );
      }
    } on AppException catch (error) {
      if (mounted) {
        _showError(context, error.userMessage);
      }
    } on Object {
      if (mounted) {
        _showError(context, failureMessage);
      }
    } finally {
      if (request != null && await request.sourceFile.exists()) {
        await request.sourceFile.delete();
      }
      if (mounted) {
        setState(() => _importing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_document.title),
      actions: [
        IconButton(
          tooltip: 'تعديل المستند',
          icon: const Icon(Icons.edit_outlined),
          onPressed: _importing ? null : _edit,
        ),
        IconButton(
          tooltip: 'حذف',
          icon: const Icon(Icons.delete_outline),
          onPressed: _delete,
        ),
      ],
    ),
    body: JibiPage(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('اضغط على المرفق لعرضه. الملفات محفوظة بشكل مشفر.'),
          FutureBuilder<Map<String, String>>(
            future: _details,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return const Text('تعذر قراءة تفاصيل المستند.');
              }
              return Column(
                children: [
                  for (final field
                      in (snapshot.data ?? <String, String>{}).entries)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(field.key),
                      subtitle: Text(field.value),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _importing ? null : _importFile,
            icon: const Icon(Icons.attach_file),
            label: Text(_importing ? 'جارٍ تشفير الملف…' : 'إرفاق ملف'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _importing ? null : _captureImage,
            icon: const Icon(Icons.photo_camera_outlined),
            label: const Text('التقاط صورة بالكاميرا'),
          ),
          const SizedBox(height: 24),
          JibiSection(
            title: 'المرفقات',
            child: FutureBuilder<List<DocumentFile>>(
              future: _files,
              builder: (context, snapshot) {
                final files = snapshot.data ?? const <DocumentFile>[];
                return files.isEmpty
                    ? const Text('لم تتم إضافة ملفات بعد.')
                    : Column(
                        children: [
                          for (final file in files)
                            ListTile(
                              leading: const Icon(Icons.lock_outline),
                              title: Text(file.originalExtension.toUpperCase()),
                              onTap: () => _previewFile(file),
                              subtitle: Text(
                                '${file.encryptedSizeBytes} bytes مشفرة',
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: 'مشاركة الملف',
                                    icon: const Icon(Icons.share_outlined),
                                    onPressed: _importing
                                        ? null
                                        : () => _shareFile(file),
                                  ),
                                  IconButton(
                                    tooltip: 'حذف الملف',
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: () => _deleteFile(file),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      );
              },
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> _delete() async {
    final confirmed = await JibiConfirmationDialog.show(
      context,
      title: 'حذف المستند',
      message: 'سيُحذف المستند وملفاته المشفرة غير المرتبطة. هل تريد المتابعة؟',
      confirmLabel: 'حذف',
      isDestructive: true,
    );
    if (confirmed != true) {
      return;
    }
    try {
      await widget.controller.deleteDocument(widget.document.id);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } on AppException catch (error) {
      if (mounted) {
        _showError(context, error.userMessage);
      }
    } on Object {
      if (mounted) {
        _showError(context, 'تعذر حذف المستند.');
      }
    }
  }

  Future<void> _previewFile(DocumentFile file) async {
    final isPdf = file.originalExtension.toLowerCase() == 'pdf';
    final isImage = file.mimeType.startsWith('image/');
    if (!isPdf && !isImage) {
      _showError(context, 'المعاينة متاحة للصور وملفات PDF.');
      return;
    }
    try {
      await widget.controller.withTemporaryFile(file, (temporary) async {
        if (!mounted) return;
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => DocumentPreviewPage(file: temporary, isPdf: isPdf),
          ),
        );
      });
    } on Object {
      if (mounted) _showError(context, 'تعذر فتح الملف بأمان.');
    }
  }

  Future<void> _shareFile(DocumentFile file) async {
    final pin = await askPinDialog(
      context,
      title: 'مشاركة المستند',
      message:
          'سيحصل التطبيق الذي تختاره على نسخة غير مشفرة من الملف. '
          'أدخل رمز PIN للمتابعة.',
    );
    if (pin == null || !mounted) return;
    setState(() => _importing = true);
    try {
      if (!await widget.controller.authorizeSharing(pin)) {
        if (mounted) _showError(context, 'رمز PIN غير صحيح.');
        return;
      }
      if (!mounted) return;
      final runExternal = ExternalActivityScope.of(context);
      await widget.controller.withTemporaryFile(
        file,
        (temporary) => runExternal(
          () => const AndroidFileSharing().share(temporary, file.mimeType),
          holdUntilResumed: true,
        ),
      );
    } on SecurityException catch (error) {
      if (mounted) _showError(context, error.userMessage);
    } on Object {
      if (mounted) _showError(context, 'تعذر تجهيز الملف للمشاركة.');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _deleteFile(DocumentFile file) async {
    final confirmed = await JibiConfirmationDialog.show(
      context,
      title: 'حذف الملف',
      message: 'هل تريد حذف هذا الملف المشفر؟',
      confirmLabel: 'حذف',
      isDestructive: true,
    );
    if (confirmed != true) {
      return;
    }
    try {
      await widget.controller.deleteDocumentFile(file);
      if (mounted) {
        setState(
          () => _files = widget.controller.listFiles(widget.document.id),
        );
      }
    } on AppException catch (error) {
      if (mounted) {
        _showError(context, error.userMessage);
      }
    } on Object {
      if (mounted) {
        _showError(context, 'تعذر حذف الملف.');
      }
    }
  }
}

String? _optional(String value) {
  final normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}

void _showError(BuildContext context, String message) {
  showJibiMessage(context, message);
}

