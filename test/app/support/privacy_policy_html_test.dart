import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jibi/app/support/privacy_policy_text.dart';

/// `docs/release/privacy-policy.html` is the public copy of the in-app policy
/// (Google Play needs a web address for it). It is generated from the same
/// text, so the two can never drift apart. After changing
/// `privacy_policy_text.dart`, regenerate it with:
///
///   flutter test test/app/support/privacy_policy_html_test.dart --dart-define=UPDATE_PRIVACY_HTML=true
const _update = bool.fromEnvironment('UPDATE_PRIVACY_HTML');

String _escape(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// Turns an email address in [text] into a link.
String _linkify(String escaped) => escaped.replaceAllMapped(
  RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'),
  (match) => '<a href="mailto:${match[0]}">${match[0]}</a>',
);

String renderPrivacyPolicyHtml() {
  final body = StringBuffer();
  for (final section in privacyPolicySections) {
    body.writeln('    <section>');
    body.writeln('      <h2>${_escape(section.title)}</h2>');
    for (final paragraph in section.paragraphs) {
      body.writeln('      <p>${_linkify(_escape(paragraph))}</p>');
    }
    if (section.bullets.isNotEmpty) {
      body.writeln('      <ul>');
      for (final bullet in section.bullets) {
        body.writeln('        <li>${_linkify(_escape(bullet))}</li>');
      }
      body.writeln('      </ul>');
    }
    body.writeln('    </section>');
  }
  return '''<!doctype html>
<html lang="ar" dir="rtl">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>سياسة الخصوصية — جيبي</title>
  <style>
    :root { color-scheme: light dark; --fg: #1d2b25; --bg: #f7faf8; --muted: #55665e; --accent: #1f6f55; --card: #ffffff; --line: #d9e5df; }
    @media (prefers-color-scheme: dark) { :root { --fg: #e6efea; --bg: #111a16; --muted: #9db0a7; --accent: #7fd6b8; --card: #182420; --line: #2a3a34; } }
    body { margin: 0; background: var(--bg); color: var(--fg); font: 16px/1.8 system-ui, "Segoe UI", Tahoma, Arial, sans-serif; }
    main { max-width: 42rem; margin: 0 auto; padding: 1.5rem 1rem 3rem; }
    h1 { margin: 0 0 .25rem; font-size: 1.6rem; color: var(--accent); }
    .updated { margin: 0 0 1.5rem; color: var(--muted); font-size: .9rem; }
    section { background: var(--card); border: 1px solid var(--line); border-radius: .75rem; padding: 1rem 1.25rem; margin: 0 0 1rem; }
    h2 { margin: 0 0 .5rem; font-size: 1.1rem; }
    p { margin: .4rem 0; }
    ul { margin: .4rem 0; padding-inline-start: 1.25rem; }
    li { margin: .3rem 0; }
    a { color: var(--accent); }
  </style>
</head>
<body>
  <main>
    <h1>سياسة الخصوصية — جيبي</h1>
    <p class="updated">آخر تحديث: ${_escape(privacyPolicyUpdated)}</p>
${body.toString().trimRight()}
  </main>
</body>
</html>
''';
}

void main() {
  test('docs/release/privacy-policy.html matches the in-app policy', () {
    final expected = renderPrivacyPolicyHtml();
    final file = File('docs/release/privacy-policy.html');
    if (_update) {
      file.writeAsStringSync(expected);
    }

    expect(
      file.existsSync() ? file.readAsStringSync() : null,
      expected,
      reason:
          'Regenerate it: flutter test '
          'test/app/support/privacy_policy_html_test.dart '
          '--dart-define=UPDATE_PRIVACY_HTML=true',
    );
  });

  test('the public policy never carries the developer phone number', () {
    expect(renderPrivacyPolicyHtml(), isNot(contains('966530882752')));
  });
}
