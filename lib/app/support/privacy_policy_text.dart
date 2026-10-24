import 'package:flutter/material.dart';

import 'support_info.dart';

/// The date the policy below was last revised.
const String privacyPolicyUpdated = '21 سبتمبر 2026';

/// One titled block of the privacy policy.
final class PrivacyPolicySection {
  const PrivacyPolicySection({
    required this.icon,
    required this.title,
    this.paragraphs = const <String>[],
    this.bullets = const <String>[],
  });

  final IconData icon;
  final String title;
  final List<String> paragraphs;
  final List<String> bullets;
}

/// What the app really does with data, section by section. Every statement
/// here describes the code: keep it in step when behaviour changes (a new
/// permission, a network call, a new kind of stored data).
const List<PrivacyPolicySection> privacyPolicySections = <PrivacyPolicySection>[
  PrivacyPolicySection(
    icon: Icons.shield_outlined,
    title: 'مقدمة',
    paragraphs: [
      'جيبي محفظة شخصية تعمل على جهازك: حساباتك وكلمات مرورك '
          'ومستنداتك تبقى عندك. توضح هذه الصفحة ما يحفظه التطبيق وكيف يحميه '
          'ومتى يخرج شيء منه، ولا يحدث ذلك إلا بطلبك.',
    ],
  ),
  PrivacyPolicySection(
    icon: Icons.storage_outlined,
    title: 'ما يحفظه التطبيق على جهازك',
    bullets: [
      'الحسابات والتصنيفات والعمليات والأرصدة.',
      'كلمات المرور وبياناتها الحساسة، وحقول المستندات الحساسة، وملفات '
          'المستندات والمرفقات (مشفرة).',
      'بيانات جهة إصدار التقارير التي تُدخلها: الاسم والعنوان وبيانات التواصل '
          'والشعار والتوقيع والختم.',
      'إعداداتك: المظهر والتاريخ والعملات وتسميات الأرصدة وغيرها.',
    ],
    paragraphs: [
      'كل ما يلي محفوظ في مساحة التطبيق الخاصة على جهازك، ولا تصل إليها '
          'التطبيقات الأخرى:',
    ],
  ),
  PrivacyPolicySection(
    icon: Icons.visibility_off_outlined,
    title: 'ما لا نجمعه',
    bullets: [
      'لا حسابات ولا تسجيل دخول ولا بريد إلكتروني ولا رقم هاتف.',
      'لا أدوات تحليل ولا إعلانات ولا تتبع لاستخدامك.',
      'لا يرسل التطبيق بياناتك إلى أي خادم، ولا نملك نسخة منها.',
    ],
  ),
  PrivacyPolicySection(
    icon: Icons.lock_outline,
    title: 'كيف نحمي بياناتك',
    bullets: [
      'رمز PIN لا يُحفظ نصًا، بل يُحفظ أثر مشفّر للتحقق منه فقط.',
      'بصمة اختيارية للدخول ولتأكيد التصدير، ويبقى الـPIN بديلًا دائمًا.',
      'إن نسيت الـPIN تنشئ رمزًا جديدًا بعد تأكيد هويتك ببصمتك أو بقفل هاتفك، '
          'دون أن تفقد بياناتك؛ فالـPIN يحرس شاشة القفل ولا يدخل في تشفير بياناتك.',
      'يتباطأ إدخال الـPIN تدريجيًا بعد خمس محاولات خاطئة متتالية.',
      'مفاتيح التشفير في مخزن مفاتيح أندرويد الآمن، وكلمات المرور والمستندات '
          'مشفرة بـAES-GCM.',
      'قفل تلقائي للتطبيق بعد مغادرته، ومنع لقطات الشاشة (خيار في الإعدادات).',
      'مسح الحافظة تلقائيًا بعد فترة قصيرة من نسخ كلمة مرور.',
      'النسخ السحابي التلقائي لأندرويد معطّل لهذا التطبيق.',
    ],
  ),
  PrivacyPolicySection(
    icon: Icons.admin_panel_settings_outlined,
    title: 'الأذونات',
    bullets: [
      'البصمة: للدخول وتأكيد الهوية عند التصدير وعرض كلمات المرور، وهي أو قفل '
          'الهاتف تؤكدان هويتك عند إنشاء PIN جديد بعد نسيانه.',
      'الإشعارات: تذكير محلي بالنسخ الاحتياطي بنص عام لا يكشف بياناتك '
          '(اختياري).',
      'إعادة التشغيل: لإعادة جدولة تلك التذكيرات بعد إعادة تشغيل الهاتف.',
      'الكاميرا والملفات: لا إذن دائم لهما؛ يلتقط تطبيق الكاميرا في النظام '
          'الصورة، ولا يصل التطبيق إلا إلى الملف الذي تختاره أنت.',
    ],
  ),
  PrivacyPolicySection(
    icon: Icons.ios_share_outlined,
    title: 'المشاركة والتصدير',
    paragraphs: [
      'لا يخرج شيء من بياناتك إلا حين تطلب تصدير تقرير أو مشاركته أو إنشاء '
          'نسخة احتياطية، ويلزم لذلك بصمتك أو الـPIN.',
    ],
    bullets: [
      'يصل الملف إلى التطبيق الذي تختاره (واتساب أو البريد أو Drive أو '
          'غيرها) وتحكمه بعد ذلك سياسة ذلك التطبيق.',
      'ملفات PDF وExcel والنصوص المصدَّرة غير مشفرة، فاختر من ترسلها إليه.',
      'النسخة الاحتياطية مشفرة بكلمة سر هي الـPIN.',
    ],
  ),
  PrivacyPolicySection(
    icon: Icons.backup_outlined,
    title: 'النسخ الاحتياطي والحذف',
    bullets: [
      'لأننا لا نملك نسخة من بياناتك، لا نستطيع استرجاعها لك إن فقدتها؛ '
          'احتفظ بنسخة احتياطية حديثة في مكان آمن.',
      'النسخة الاحتياطية تُفتح بالـPIN الذي كان مستخدمًا عند إنشائها. إن غيّرت '
          'الـPIN أو أنشأت غيره بعد نسيانه فأنشئ نسخة جديدة، وتبقى النسخ '
          'السابقة بحاجة إلى الـPIN القديم.',
      'عند تحديث بنية قاعدة البيانات في إصدار جديد قد يحتفظ التطبيق داخل '
          'مساحته الخاصة بنسختي أمان من القاعدة قبل التحديث؛ تُحذفان مع '
          'بيانات التطبيق.',
      'حذف التطبيق يمسح بياناته المحلية من الجهاز، وما حفظتَه خارجه '
          '(نسخ احتياطية أو تقارير) يبقى بيدك.',
    ],
  ),
  PrivacyPolicySection(
    icon: Icons.support_agent,
    title: 'التواصل مع الدعم',
    paragraphs: [
      'التواصل معنا اختياري. الرسالة الجاهزة تتضمن اسم التطبيق ورقم إصداره '
          'فقط، ويمكنك تعديلها قبل إرسالها. ما تكتبه يصل إلى المطور عبر '
          'الخدمة التي تختارها (واتساب أو البريد أو الاتصال) وتحكمه سياسة '
          'تلك الخدمة، ولا يرسل التطبيق أي بيانات منه.',
    ],
  ),
  PrivacyPolicySection(
    icon: Icons.person_outline,
    title: 'الجهة المطوِّرة',
    paragraphs: [
      'جيبي من تطوير موقع ${SupportContact.websiteLabel}. للاستفسار عن هذه '
          'السياسة أو عن خصوصيتك راسلنا على ${SupportContact.email}.',
    ],
  ),
  PrivacyPolicySection(
    icon: Icons.update,
    title: 'تعديل هذه السياسة',
    paragraphs: [
      'إذا تغيّر ما يفعله التطبيق ببياناتك تُحدَّث هذه الصفحة مع الإصدار '
          'الجديد، ويظهر تاريخ آخر تحديث في أعلاها.',
    ],
  ),
];
