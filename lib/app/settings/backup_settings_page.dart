import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/backup/backup_file_transfer.dart';
import '../../core/backup/backup_schedule.dart';
import '../../core/errors/app_exception.dart';
import '../../core/models/models.dart';
import '../../shared/widgets/jibi_design.dart';
import '../../shared/widgets/jibi_feedback.dart';
import '../../shared/widgets/pin_prompt.dart';
import '../jibi_application.dart';
import 'settings_widgets.dart';

/// What the local backups look like right now.
final class _BackupInfo {
  const _BackupInfo({this.lastAt, this.lastSizeBytes, this.count = 0});

  final DateTime? lastAt;
  final int? lastSizeBytes;
  final int count;
}

/// "النسخ الاحتياطي" (المتطلبات 59–61): create, save, share and restore an
/// encrypted backup, see when and how big the last one is, and the reminders.
///
/// A backup is the whole database (user data, categories, accounts,
/// transactions, currencies, settings) plus the encrypted attachment files,
/// encrypted with the PIN. Restoring first makes a safety copy of the current
/// data.
class BackupSettingsPage extends StatefulWidget {
  const BackupSettingsPage({
    required this.application,
    this.fileTransfer = const AndroidBackupFileTransfer(),
    super.key,
  });

  final JibiApplication application;

  /// Moves backup files in and out of the phone; replaced in tests.
  final BackupFileTransfer fileTransfer;

  @override
  State<BackupSettingsPage> createState() => _BackupSettingsPageState();
}

class _BackupSettingsPageState extends State<BackupSettingsPage> {
  bool _busy = false;
  late Future<_BackupInfo> _info = _readInfo();

  JibiApplication get _application => widget.application;

  Future<_BackupInfo> _readInfo() async {
    try {
      final directory = _application.backupDirectory;
      if (!await directory.exists()) return const _BackupInfo();
      File? latest;
      DateTime? latestAt;
      var count = 0;
      await for (final entity in directory.list(followLinks: false)) {
        if (!isListedBackup(entity)) continue;
        count++;
        final modified = await (entity as File).lastModified();
        if (latestAt == null || modified.isAfter(latestAt)) {
          latest = entity;
          latestAt = modified;
        }
      }
      return _BackupInfo(
        lastAt: latestAt,
        lastSizeBytes: latest == null ? null : await latest.length(),
        count: count,
      );
    } on Object {
      return const _BackupInfo();
    }
  }

  void _refreshInfo() => setState(() => _info = _readInfo());

  static String _size(int bytes) {
    if (bytes < 1024) return '$bytes بايت';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} ك.ب';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} م.ب';
  }

  Future<void> _save(AppSettings settings) async {
    setState(() => _busy = true);
    await saveSettingsOrShow(context, _application, settings);
    if (mounted) setState(() => _busy = false);
  }

  /// Saves the schedule and, when reminders are turned on, asks the system for
  /// notification permission (Android 13+). Refusing only means no popups: the
  /// reminder banner inside the app keeps working.
  Future<void> _setSchedule(BackupSchedule schedule) async {
    await _save(_application.settings.copyWith(backupSchedule: schedule));
    if (schedule == BackupSchedule.off || !mounted) return;
    final scheduler = _application.notificationScheduler;
    final granted =
        await scheduler.isPermitted() || await scheduler.requestPermission();
    if (!mounted) return;
    await _application.reminders.sync();
    if (!granted && mounted) {
      showJibiMessage(
        context,
        'الإشعارات غير مسموحة، لذا سيظهر التذكير داخل التطبيق فقط.',
      );
    }
  }

  Future<void> _create({required bool share}) async {
    final pin = await askPinDialog(
      context,
      title: 'تأكيد رمز PIN',
      message: 'أدخل رمز PIN الحالي لتشفير النسخة الاحتياطية.',
    );
    if (pin == null || !mounted) return;
    setState(() => _busy = true);
    try {
      if (!await _application.security.verifyPin(pin)) {
        if (mounted) showJibiMessage(context, 'رمز PIN غير صحيح.');
        return;
      }
      if (!mounted) return;
      showJibiMessage(context, 'جارٍ إنشاء النسخة الاحتياطية...');
      final backup = await _application.createBackup(pin: pin);
      final exported = await _application.runExternalActivity(
        () => widget.fileTransfer.export(
          backup.file,
          suggestedName: backup.shareName,
          preferGoogleDrive: share,
        ),
        holdUntilResumed: share,
      );
      if (!mounted) return;
      if (share) {
        // Android cannot tell us whether the upload finishes, so this never
        // claims success: it only says the share screen was opened.
        showJibiMessage(
          context,
          exported
              ? 'فُتحت نافذة المشاركة. تأكد من اكتمال الحفظ أو الرفع. النسخة محفوظة أيضاً داخل التطبيق.'
              : 'تعذر فتح نافذة المشاركة. النسخة محفوظة داخل التطبيق.',
        );
      } else {
        showJibiMessage(
          context,
          exported
              ? 'تم حفظ النسخة الاحتياطية بنجاح (${_size(backup.descriptor.sizeBytes)}).'
              : 'تم إلغاء الحفظ. النسخة محفوظة داخل التطبيق.',
        );
      }
    } on AppException catch (error) {
      if (mounted) showJibiMessage(context, error.userMessage);
    } on Object {
      if (mounted) showJibiMessage(context, 'تعذر إنشاء النسخة الاحتياطية.');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _refreshInfo();
      }
    }
  }

  Future<void> _import() async {
    File? imported;
    try {
      imported = await _application.runExternalActivity(
        widget.fileTransfer.import,
      );
      if (imported == null || !mounted) return;
      await _restore(imported);
    } on AppException catch (error) {
      if (mounted) showJibiMessage(context, error.userMessage);
    } on Object {
      if (mounted) showJibiMessage(context, 'ملف النسخة الاحتياطية غير صالح.');
    } finally {
      if (imported != null && await imported.exists()) {
        await imported.delete();
      }
    }
  }

  Future<void> _openLocal() async {
    final files =
        (await _application.backupDirectory
              .list()
              .where((entity) => isListedBackup(entity))
              .cast<File>()
              .toList())
          ..sort((left, right) {
            final time = right.lastModifiedSync().compareTo(
              left.lastModifiedSync(),
            );
            return time != 0 ? time : right.path.compareTo(left.path);
          });
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          key: const Key('backup-local-sheet'),
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text(
                'النسخ المحفوظة داخل التطبيق',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            if (files.isEmpty)
              const ListTile(title: Text('لا توجد نسخ محلية بعد.')),
            for (final file in files)
              ListTile(
                leading: const Icon(Icons.lock_outline),
                title: Text(
                  BookTransaction.formatStamp(file.lastModifiedSync()),
                  textDirection: TextDirection.ltr,
                  textAlign: TextAlign.end,
                ),
                subtitle: Text(_size(file.lengthSync())),
                trailing: const Text('استعادة'),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await _restore(file);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _restore(File file) async {
    final confirmed = await JibiConfirmationDialog.show(
      context,
      title: 'استعادة النسخة',
      message:
          'هل أنت متأكد من استعادة هذه النسخة؟ سيتم استبدال البيانات الحالية '
          'بعد حفظ نسخة أمان منها تلقائياً.',
      confirmLabel: 'استعادة',
      isDestructive: true,
    );
    if (confirmed != true || !mounted) return;
    final pin = await askPinDialog(
      context,
      title: 'رمز PIN للنسخة',
      message: 'أدخل رمز PIN الذي استُخدم عند إنشاء النسخة.',
    );
    if (pin == null || !mounted) return;
    setState(() => _busy = true);
    try {
      showJibiMessage(context, 'جارٍ استعادة النسخة الاحتياطية...');
      await _application.backupService.restoreLocalBackup(
        source: file,
        recoveryPassword: pin,
      );
      await _application.refreshAfterRestore();
      if (mounted) {
        showJibiMessage(context, 'تمت استعادة النسخة الاحتياطية بنجاح.');
      }
    } on AppException catch (error) {
      if (mounted) showJibiMessage(context, error.userMessage);
    } on Object {
      if (mounted) showJibiMessage(context, 'تعذر استعادة النسخة الاحتياطية.');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _refreshInfo();
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('النسخ الاحتياطي')),
    body: ValueListenableBuilder<AppSettings>(
      valueListenable: _application.settingsListenable,
      builder: (context, settings, _) => ListView(
        key: const Key('backup-settings'),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          if (_busy) const LinearProgressIndicator(minHeight: 3),
          FutureBuilder<_BackupInfo>(
            future: _info,
            builder: (context, snapshot) {
              final info = snapshot.data;
              final due = shouldRunBackup(
                schedule: settings.backupSchedule,
                lastRun: info?.lastAt,
                now: DateTime.now().toUtc(),
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (due && info != null)
                    Container(
                      key: const Key('backup-due'),
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: JibiColors.gold.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.notification_important_outlined),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'حان وقت نسخة احتياطية. احفظ نسخة مشفرة برمز PIN الحالي.',
                            ),
                          ),
                        ],
                      ),
                    ),
                  SettingsGroup(
                    title: 'آخر نسخة',
                    children: [
                      _InfoRow(
                        key: const Key('backup-last-date'),
                        label: 'تاريخ آخر نسخة',
                        value: info == null
                            ? '…'
                            : info.lastAt == null
                            ? 'لا توجد نسخة بعد'
                            : '${BookTransaction.formatStamp(info.lastAt!)} '
                                  '(${jibiRelativeTimeAr(info.lastAt!)})',
                      ),
                      _InfoRow(
                        key: const Key('backup-last-size'),
                        label: 'حجم آخر نسخة',
                        value: info == null
                            ? '…'
                            : info.lastSizeBytes == null
                            ? '—'
                            : _size(info.lastSizeBytes!),
                      ),
                      _InfoRow(
                        key: const Key('backup-count'),
                        label: 'النسخ المحفوظة داخل التطبيق',
                        value: info == null ? '…' : '${info.count}',
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
          SettingsGroup(
            title: 'ما تشمله النسخة',
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  'بيانات المستخدم • التصنيفات • الحسابات • العمليات • العملات • '
                  'المرفقات • الإعدادات. تُشفَّر برمز PIN داخل ملف واحد. '
                  'قبل الاستعادة تُحفظ نسخة أمان من بياناتك الحالية تلقائياً.',
                  style: TextStyle(fontSize: 12.5, color: context.jibiMuted),
                ),
              ),
            ],
          ),
          SettingsGroup(
            title: 'الإجراءات',
            children: [
              FilledButton.icon(
                key: const Key('backup-save-device'),
                onPressed: _busy ? null : () => _create(share: false),
                icon: const Icon(Icons.phone_android_outlined),
                label: const Text('إنشاء نسخة وحفظها على الجهاز'),
              ),
              FilledButton.tonalIcon(
                key: const Key('backup-share'),
                onPressed: _busy ? null : () => _create(share: true),
                icon: const Icon(Icons.ios_share_outlined),
                label: const Text('إنشاء نسخة ومشاركتها (Drive وغيره)'),
              ),
              OutlinedButton.icon(
                key: const Key('backup-restore'),
                onPressed: _busy ? null : _import,
                icon: const Icon(Icons.restore_outlined),
                label: const Text('استعادة نسخة احتياطية'),
              ),
              TextButton.icon(
                key: const Key('backup-local-list'),
                onPressed: _busy ? null : _openLocal,
                icon: const Icon(Icons.folder_outlined),
                label: const Text('عرض النسخ المحفوظة داخل التطبيق'),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  'المشاركة تفتح نافذة الهاتف (Google Drive وغيره) ويتولى التطبيق '
                  'المختار الحفظ أو الرفع؛ لا يستطيع جيبي التأكد من اكتماله ولا '
                  'يوجد تسجيل دخول Google داخل التطبيق.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
          SettingsGroup(
            title: 'التذكير والاحتفاظ',
            children: [
              DropdownButtonFormField<BackupSchedule>(
                key: ValueKey('schedule-${settings.backupSchedule.name}'),
                initialValue: settings.backupSchedule,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'تذكير النسخ الاحتياطي',
                ),
                items: const [
                  DropdownMenuItem(
                    value: BackupSchedule.off,
                    child: Text('إيقاف التذكير'),
                  ),
                  DropdownMenuItem(
                    value: BackupSchedule.daily,
                    child: Text('يومياً'),
                  ),
                  DropdownMenuItem(
                    value: BackupSchedule.weekly,
                    child: Text('أسبوعياً'),
                  ),
                  DropdownMenuItem(
                    value: BackupSchedule.monthly,
                    child: Text('شهرياً'),
                  ),
                ],
                onChanged: _busy
                    ? null
                    : (schedule) {
                        if (schedule != null) unawaited(_setSchedule(schedule));
                      },
              ),
              SwitchListTile(
                key: const Key('backup-auto'),
                contentPadding: EdgeInsets.zero,
                title: const Text('نسخ تلقائي عند فتح التطبيق'),
                subtitle: const Text(
                  'ينشئ نسخة عند استحقاقها بعد الدخول برمز PIN. لا يعمل مع الدخول بالبصمة لأن PIN غير محفوظ.',
                ),
                value: settings.autoBackupOnUnlock,
                onChanged: _busy || settings.backupSchedule == BackupSchedule.off
                    ? null
                    : (enabled) =>
                          _save(settings.copyWith(autoBackupOnUnlock: enabled)),
              ),
              DropdownButtonFormField<int>(
                key: ValueKey('retention-${settings.backupRetentionCount}'),
                initialValue: settings.backupRetentionCount,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'الاحتفاظ بآخر نسخ',
                ),
                items: const [
                  DropdownMenuItem(value: 1, child: Text('نسخة واحدة')),
                  DropdownMenuItem(value: 3, child: Text('3 نسخ')),
                  DropdownMenuItem(value: 5, child: Text('5 نسخ')),
                  DropdownMenuItem(value: 10, child: Text('10 نسخ')),
                ],
                onChanged: _busy
                    ? null
                    : (count) {
                        if (count != null) {
                          _save(settings.copyWith(backupRetentionCount: count));
                        }
                      },
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value, super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(child: Text(label)),
      const SizedBox(width: 8),
      Flexible(
        child: Text(
          value,
          textAlign: TextAlign.end,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: context.jibiMuted,
          ),
        ),
      ),
    ],
  );
}
