import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no hardcoded user-facing strings in presentation/services', () {
    final pattern = RegExp(
      r'''(Text|SnackBar\(content: Text|label: Text|title: Text|tooltip:)\s*\(?\s*(const\s+)?['"][A-Z][a-z]''',
    );
    final offenders = <String>[];
    for (final dir in ['lib/presentation', 'lib/services']) {
      for (final f in Directory(
        dir,
      ).listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (pattern.hasMatch(lines[i]) &&
              !lines[i].contains('l10n.') &&
              !lines[i].contains('// l10n-exempt')) {
            offenders.add('${f.path}:${i + 1}: ${lines[i].trim()}');
          }
        }
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });
}
