import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop display rename preserves the existing profile identities', () {
    final windows = File('windows/runner/Runner.rc').readAsStringSync();
    expect(windows, contains('VALUE "CompanyName", "com.songloft"'));
    expect(windows, contains('VALUE "ProductName", "Songloft"'));
    expect(
      File('linux/CMakeLists.txt').readAsStringSync(),
      contains('set(APPLICATION_ID "com.songloft.songloft_flutter")'),
    );
    for (final platform in ['windows', 'linux']) {
      expect(
        File('$platform/CMakeLists.txt').readAsStringSync(),
        contains('set(BINARY_NAME "roomtone")'),
      );
    }
  });
}
