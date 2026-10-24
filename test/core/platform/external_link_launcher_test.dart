import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/core/platform/external_link_launcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.jibi.jibi/external_links');
  final calls = <MethodCall>[];
  Object? reply;

  setUp(() {
    calls.clear();
    reply = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (reply is PlatformException) throw reply! as PlatformException;
          return reply;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  const launcher = AndroidExternalLinkLauncher();

  test('the WhatsApp link encodes spaces as %20 and never as a plus', () {
    final link = AndroidExternalLinkLauncher.whatsAppLink(
      '966500000000',
      'السلام عليكم\nالإصدار: 1.0',
    );
    expect(link, startsWith('https://wa.me/966500000000?text='));
    final query = link.substring(link.indexOf('?text=') + 6);
    expect(query, isNot(contains('+')));
    expect(query, isNot(contains(' ')));
    expect(query, contains('%20'));
    expect(query, contains('%0A'));
    // It decodes back to exactly the message.
    expect(Uri.decodeComponent(query), 'السلام عليكم\nالإصدار: 1.0');
  });

  test('WhatsApp goes with the link and WhatsApp then Business, in order', () async {
    final opened = await launcher.openWhatsApp(
      phone: '966500000000',
      message: 'مرحبا',
    );

    expect(opened, isTrue);
    expect(calls.single.method, 'openWhatsApp');
    final arguments = calls.single.arguments as Map<Object?, Object?>;
    expect(
      arguments['url'],
      AndroidExternalLinkLauncher.whatsAppLink('966500000000', 'مرحبا'),
    );
    expect(arguments['preferredPackages'], [
      'com.whatsapp',
      'com.whatsapp.w4b',
    ]);
  });

  test('the dialer gets the digits only (the platform adds the plus)', () async {
    expect(await launcher.dial('966500000000'), isTrue);

    expect(calls.single.method, 'dial');
    expect(calls.single.arguments, {'phone': '966500000000'});
  });

  test('the mail carries its address, subject and body', () async {
    expect(
      await launcher.composeEmail(
        to: 'someone@example.com',
        subject: 'موضوع',
        body: 'نص',
      ),
      isTrue,
    );

    expect(calls.single.method, 'composeEmail');
    expect(calls.single.arguments, {
      'to': 'someone@example.com',
      'subject': 'موضوع',
      'body': 'نص',
    });
  });

  test('the website goes as a full https address', () async {
    expect(await launcher.openWebsite(Uri.parse('https://alaw9l.com/')), isTrue);

    expect(calls.single.method, 'openWebsite');
    expect(calls.single.arguments, {'url': 'https://alaw9l.com/'});
  });

  test('false and null mean that no app took the request', () async {
    reply = false;
    expect(await launcher.dial('966500000000'), isFalse);
    reply = null;
    expect(await launcher.dial('966500000000'), isFalse);
  });

  test('a platform failure is not hidden', () async {
    reply = PlatformException(code: 'open_failed');

    await expectLater(
      launcher.dial('966500000000'),
      throwsA(isA<PlatformException>()),
    );
  });
}
