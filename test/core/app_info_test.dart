import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/core/app_info.dart';

void main() {
  test('AppInfo matches the version declared in pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final declared = RegExp(
      r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec);

    expect(declared, isNotNull, reason: 'pubspec.yaml must declare a version');
    expect(AppInfo.version, declared!.group(1));
    expect(AppInfo.buildNumber, int.parse(declared.group(2)!));
    expect(AppInfo.display, '${AppInfo.version} (بناء ${AppInfo.buildNumber})');
  });
}
