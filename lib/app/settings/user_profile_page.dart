import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/errors/app_exception.dart';
import '../../core/models/models.dart';
import '../../core/storage/document_source_picker.dart';
import '../../features/profile/user_profile_controller.dart';
import '../../shared/widgets/jibi_design.dart';
import '../../shared/widgets/jibi_feedback.dart';
import '../jibi_application.dart';

/// Where a profile picture comes from.
enum ProfileImageSource { files, camera }

/// Returns the raw bytes of a picture the user chose, or null when cancelled.
typedef ProfileImagePicker =
    Future<Uint8List?> Function(ProfileImageSource source);

/// "بيانات المستخدم" (المتطلبات 49–52): names, contact details and the logo,
/// signature and stamp printed on reports.
class UserProfilePage extends StatefulWidget {
  const UserProfilePage({
    required this.application,
    this.pickImage,
    super.key,
  });

  final JibiApplication application;

  /// Replaces the device picker (tests).
  final ProfileImagePicker? pickImage;

  @override
  State<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends State<UserProfilePage> {
  late final UserProfile _initial = widget.application.profile.current;
  late final _nameAr = TextEditingController(text: _initial.nameAr);
  late final _nameEn = TextEditingController(text: _initial.nameEn);
  late final _addressAr = TextEditingController(text: _initial.addressAr);
  late final _addressEn = TextEditingController(text: _initial.addressEn);
  late final _phone = TextEditingController(text: _initial.phone);
  late final _email = TextEditingController(text: _initial.email);
  late Uint8List? _logo = _initial.logo;
  late Uint8List? _signature = _initial.signature;
  late Uint8List? _stamp = _initial.stamp;
  late bool _showLogo = _initial.showLogo;
  late bool _showSignature = _initial.showSignature;
  late bool _showStamp = _initial.showStamp;
  bool _saving = false;
  bool _dirty = false;

  @override
  void dispose() {
    for (final controller in [
      _nameAr,
      _nameEn,
      _addressAr,
      _addressEn,
      _phone,
      _email,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _touch() {
    if (!_dirty) setState(() => _dirty = true);
  }

  Future<Uint8List?> _pickFromDevice(ProfileImageSource source) async {
    const picker = AndroidDocumentSourcePicker();
    final request = await widget.application.runExternalActivity(
      () => source == ProfileImageSource.camera
          ? picker.captureImage()
          : picker.pickFile(),
    );
    if (request == null) return null;
    try {
      return await request.sourceFile.readAsBytes();
    } finally {
      try {
        await request.sourceFile.delete();
      } on FileSystemException {
        // A leftover in the cache folder is cleaned by the system.
      }
    }
  }

  Future<void> _choose(ProfileImageSlot slot) async {
    final source = await showModalBottomSheet<ProfileImageSource>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('profile-source-files'),
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('من المعرض أو الملفات'),
              onTap: () =>
                  Navigator.of(sheetContext).pop(ProfileImageSource.files),
            ),
            ListTile(
              key: const Key('profile-source-camera'),
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('التقاط صورة بالكاميرا'),
              onTap: () =>
                  Navigator.of(sheetContext).pop(ProfileImageSource.camera),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;
    try {
      final bytes = await (widget.pickImage ?? _pickFromDevice)(source);
      if (bytes == null || !mounted) return;
      setState(() => _saving = true);
      final prepared = await widget.application.profile.prepareImage(
        bytes,
        slot,
      );
      if (!mounted) return;
      setState(() {
        switch (slot) {
          case ProfileImageSlot.logo:
            _logo = prepared;
            _showLogo = true;
          case ProfileImageSlot.signature:
            _signature = prepared;
            _showSignature = true;
          case ProfileImageSlot.stamp:
            _stamp = prepared;
            _showStamp = true;
        }
        _dirty = true;
      });
    } on AppException catch (error) {
      if (mounted) showJibiMessage(context, error.userMessage);
    } on Object {
      if (mounted) showJibiMessage(context, 'تعذر تحميل الصورة.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _remove(ProfileImageSlot slot) => setState(() {
    switch (slot) {
      case ProfileImageSlot.logo:
        _logo = null;
      case ProfileImageSlot.signature:
        _signature = null;
      case ProfileImageSlot.stamp:
        _stamp = null;
    }
    _dirty = true;
  });

  Future<void> _save() async {
    final UserProfile profile;
    try {
      profile = UserProfile.validated(
        nameAr: _nameAr.text,
        nameEn: _nameEn.text,
        addressAr: _addressAr.text,
        addressEn: _addressEn.text,
        phone: _phone.text,
        email: _email.text,
        logo: _logo,
        signature: _signature,
        stamp: _stamp,
        showLogo: _showLogo,
        showSignature: _showSignature,
        showStamp: _showStamp,
      );
    } on AppException catch (error) {
      showJibiMessage(context, error.userMessage);
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.application.profile.save(profile);
      if (!mounted) return;
      _dirty = false;
      showJibiMessage(context, 'تم حفظ بيانات المستخدم.');
      Navigator.of(context).pop();
    } on AppException catch (error) {
      if (mounted) showJibiMessage(context, error.userMessage);
    } on Object {
      if (mounted) showJibiMessage(context, 'تعذر حفظ بيانات المستخدم.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmDiscard() async {
    final discard = await JibiConfirmationDialog.show(
      context,
      title: 'تجاهل التغييرات؟',
      message: 'لم تحفظ التعديلات على بيانات المستخدم.',
      confirmLabel: 'تجاهل',
      isDestructive: true,
    );
    if (discard == true && mounted) {
      setState(() => _dirty = false);
      Navigator.of(context).pop();
    }
  }

  Widget _field(
    String key,
    String label,
    TextEditingController controller, {
    bool ltr = false,
    TextInputType? keyboard,
    int maxLines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      key: Key(key),
      controller: controller,
      enabled: !_saving,
      maxLines: maxLines,
      minLines: 1,
      keyboardType: keyboard,
      textDirection: ltr ? TextDirection.ltr : null,
      textAlign: ltr ? TextAlign.left : TextAlign.start,
      onChanged: (_) => _touch(),
      decoration: InputDecoration(labelText: label),
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_dirty,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _confirmDiscard();
    },
    child: Scaffold(
      appBar: AppBar(title: const Text('بيانات المستخدم')),
      body: ListView(
        key: const Key('profile-form'),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          Text(
            'تظهر هذه البيانات في رأس التقارير وملفات PDF وكشوف الحساب.',
            style: TextStyle(color: context.jibiMuted, fontSize: 13),
          ),
          const SizedBox(height: 16),
          _ImageSlot(
            prefix: 'logo',
            title: 'الشعار',
            hint: 'يظهر أعلى التقارير.',
            bytes: _logo,
            show: _showLogo,
            busy: _saving,
            onPick: () => _choose(ProfileImageSlot.logo),
            onRemove: () => _remove(ProfileImageSlot.logo),
            onShow: (value) => setState(() {
              _showLogo = value;
              _dirty = true;
            }),
          ),
          const SizedBox(height: 16),
          _field('profile-name-ar', 'الاسم العربي', _nameAr),
          _field('profile-name-en', 'الاسم الإنجليزي', _nameEn, ltr: true),
          _field('profile-address-ar', 'العنوان العربي', _addressAr, maxLines: 2),
          _field(
            'profile-address-en',
            'العنوان الإنجليزي',
            _addressEn,
            ltr: true,
            maxLines: 2,
          ),
          _field(
            'profile-phone',
            'رقم الهاتف',
            _phone,
            ltr: true,
            keyboard: TextInputType.phone,
          ),
          _field(
            'profile-email',
            'البريد الإلكتروني',
            _email,
            ltr: true,
            keyboard: TextInputType.emailAddress,
          ),
          const SizedBox(height: 4),
          _ImageSlot(
            prefix: 'signature',
            title: 'التوقيع',
            hint: 'يظهر في نهاية التقرير. يفضّل توقيع على خلفية شفافة أو بيضاء.',
            bytes: _signature,
            show: _showSignature,
            busy: _saving,
            onPick: () => _choose(ProfileImageSlot.signature),
            onRemove: () => _remove(ProfileImageSlot.signature),
            onShow: (value) => setState(() {
              _showSignature = value;
              _dirty = true;
            }),
          ),
          const SizedBox(height: 16),
          _ImageSlot(
            prefix: 'stamp',
            title: 'الختم',
            hint: 'يظهر في نهاية التقرير بجانب التوقيع.',
            bytes: _stamp,
            show: _showStamp,
            busy: _saving,
            onPick: () => _choose(ProfileImageSlot.stamp),
            onRemove: () => _remove(ProfileImageSlot.stamp),
            onShow: (value) => setState(() {
              _showStamp = value;
              _dirty = true;
            }),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton(
            key: const Key('profile-save'),
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('حفظ'),
          ),
        ),
      ),
    ),
  );
}

/// One picture of the profile: preview, choose/replace, delete and the switch
/// that decides whether it is printed.
class _ImageSlot extends StatelessWidget {
  const _ImageSlot({
    required this.prefix,
    required this.title,
    required this.hint,
    required this.bytes,
    required this.show,
    required this.busy,
    required this.onPick,
    required this.onRemove,
    required this.onShow,
  });

  final String prefix;
  final String title;
  final String hint;
  final Uint8List? bytes;
  final bool show;
  final bool busy;
  final VoidCallback onPick;
  final VoidCallback onRemove;
  final ValueChanged<bool> onShow;

  @override
  Widget build(BuildContext context) => JibiSoftCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 2),
        Text(hint, style: TextStyle(fontSize: 12, color: context.jibiMuted)),
        const SizedBox(height: 12),
        Row(
          children: [
            Container(
              key: Key('profile-$prefix-preview'),
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: Theme.of(context).dividerColor.withValues(alpha: 0.6),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: bytes == null
                  ? Icon(Icons.image_outlined, color: context.jibiMuted)
                  : Image.memory(
                      bytes!,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => Icon(
                        Icons.broken_image_outlined,
                        color: context.jibiMuted,
                      ),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  OutlinedButton.icon(
                    key: Key('profile-$prefix-pick'),
                    onPressed: busy ? null : onPick,
                    icon: const Icon(
                      Icons.add_photo_alternate_outlined,
                      size: 18,
                    ),
                    label: Text(bytes == null ? 'إضافة' : 'تغيير'),
                  ),
                  if (bytes != null)
                    TextButton.icon(
                      key: Key('profile-$prefix-delete'),
                      onPressed: busy ? null : onRemove,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('حذف'),
                    ),
                ],
              ),
            ),
          ],
        ),
        SwitchListTile(
          key: Key('profile-$prefix-show'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('إظهاره في التقارير'),
          value: show,
          onChanged: busy ? null : onShow,
        ),
      ],
    ),
  );
}
