import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/app/support/support_info.dart';
import 'package:jibi/core/app_info.dart';

void main() {
  test('the contact details are the developer\'s', () {
    expect(SupportContact.email, 'abdurahmansharf@gmail.com');
    expect(SupportContact.phone, '966530882752');
    expect(SupportContact.website.toString(), 'https://alaw9l.com/');
    expect(SupportContact.websiteLabel, 'alaw9l.com');
  });

  test('the WhatsApp message asks for support and names the version only', () {
    final message = SupportContact.whatsAppMessage();
    expect(message, contains('دعم فني'));
    expect(message, contains('جيبي'));
    expect(message, contains(AppInfo.display));
    // It ends where the user starts typing.
    expect(message.trimRight(), endsWith('وصف المشكلة أو الاقتراح:'));
    expect(message, isNot(contains(SupportContact.phone)));
    expect(message, isNot(contains(SupportContact.email)));
  });

  test('the email carries the version in its subject and body', () {
    expect(SupportContact.emailSubject(), contains('دعم فني'));
    expect(SupportContact.emailSubject(), contains(AppInfo.version));
    expect(SupportContact.emailBody(), contains(AppInfo.display));
    expect(SupportContact.emailBody(), isNot(contains(SupportContact.phone)));
  });
}
