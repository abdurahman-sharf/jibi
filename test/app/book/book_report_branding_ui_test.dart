import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/app/book/reports/book_report_preview_page.dart';
import 'package:jibi/features/book/reports/report_models.dart';

import '../../support/book_harness.dart';

/// A 1x1 PNG.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

ReportDocument _document(ReportBranding? branding) => ReportDocument(
  kind: ReportKind.accountStatement,
  title: 'كشف حساب',
  info: const [ReportInfo('الحساب', 'علي أخي')],
  blocks: const [],
  generatedAt: DateTime(2026, 9, 20, 15, 30),
  fileBaseName: 'كشف حساب',
  notes: const ['لا توجد بيانات.'],
  branding: branding,
);

void main() {
  late BookFixture fixture;

  setUp(() async {
    fixture = await BookFixture.create(seed: false);
  });

  tearDown(() => fixture.dispose());

  Future<void> show(WidgetTester tester, ReportDocument document) => pumpBookPage(
    tester,
    Scaffold(
      body: ReportDocumentView(document: document, book: fixture.book),
    ),
  );

  testWidgets('the letterhead shows the names, the contact details and the logo',
      (tester) async {
    await show(
      tester,
      _document(
        ReportBranding(
          nameAr: 'عبدالرحمن شرف',
          nameEn: 'Abdulrahman Sharaf',
          addressAr: 'صنعاء',
          phone: '777123456',
          email: 'a@example.com',
          logo: _png,
        ),
      ),
    );

    final head = find.byKey(const Key('report-letterhead'));
    expect(head, findsOneWidget);
    for (final text in [
      'عبدالرحمن شرف',
      'Abdulrahman Sharaf',
      'صنعاء',
      '777123456  ·  a@example.com',
    ]) {
      expect(
        find.descendant(of: head, matching: find.text(text)),
        findsOneWidget,
        reason: text,
      );
    }
    expect(
      find.descendant(of: head, matching: find.byType(Image)),
      findsOneWidget,
    );
    expect(find.byKey(const Key('report-signatures')), findsNothing);
    // The report itself is unchanged below it.
    expect(find.text('علي أخي'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the signature and the stamp close the report', (tester) async {
    await show(
      tester,
      _document(ReportBranding(signature: _png, stamp: _png)),
    );

    final closing = find.byKey(const Key('report-signatures'));
    expect(closing, findsOneWidget);
    expect(find.descendant(of: closing, matching: find.text('التوقيع')), findsOneWidget);
    expect(find.descendant(of: closing, matching: find.text('الختم')), findsOneWidget);
    expect(find.descendant(of: closing, matching: find.byType(Image)), findsNWidgets(2));
    expect(find.byKey(const Key('report-letterhead')), findsNothing);
  });

  testWidgets('only the picture that exists gets its slot', (tester) async {
    await show(tester, _document(ReportBranding(stamp: _png)));

    final closing = find.byKey(const Key('report-signatures'));
    expect(find.descendant(of: closing, matching: find.text('الختم')), findsOneWidget);
    expect(find.descendant(of: closing, matching: find.text('التوقيع')), findsNothing);
  });

  testWidgets('without a profile the report has neither part', (tester) async {
    await show(tester, _document(null));

    expect(find.byKey(const Key('report-letterhead')), findsNothing);
    expect(find.byKey(const Key('report-signatures')), findsNothing);
  });

  testWidgets('a damaged picture never breaks the preview', (tester) async {
    await show(
      tester,
      _document(
        ReportBranding(
          nameAr: 'أنا',
          logo: Uint8List.fromList([1, 2, 3]),
          signature: Uint8List.fromList([4, 5, 6]),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const Key('report-letterhead')), findsOneWidget);
    expect(find.byKey(const Key('report-signatures')), findsOneWidget);
  });
}
