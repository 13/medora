import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('presentation layer uses theme tokens, not static colors', () {
    final offenders = <String>[];
    final allowed = RegExp(r'Colors\.(transparent|black)\b');
    for (final file in Directory(
      'lib/presentation',
    ).listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final hasStatic = RegExp(
          r'AppTheme\.\w+Color\b|AppTheme\.primary(Light|Dark)\b',
        ).hasMatch(line);
        // Check every `Colors.` occurrence on its own: a line-wide
        // `allowed` match used to whitelist the whole line, so
        // `Colors.transparent` next to `Colors.red` slipped through.
        final hasColors = RegExp(
          r'\bColors\.\w+',
        ).allMatches(line).any((m) => !allowed.hasMatch(m[0]!));
        if (hasStatic || hasColors)
          offenders.add('${file.path}:${i + 1}: ${line.trim()}');
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });
}
