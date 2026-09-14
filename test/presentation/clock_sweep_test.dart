import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `lib/core/clock.dart` is the single "now" seam: everything else takes the
/// time from `nowProvider` / an injected clock, so tests can pin it.
void main() {
  test('presentation and domain read the clock through the seam', () {
    final wallClock = RegExp(
      r'\b(DateTime\.now\(|DateTime\.timestamp\(|TimeOfDay\.now\()',
    );
    final offenders = <String>[];
    for (final dir in ['lib/presentation', 'lib/domain']) {
      for (final file in Directory(
        dir,
      ).listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (wallClock.hasMatch(lines[i])) {
            offenders.add('${file.path}:${i + 1}: ${lines[i].trim()}');
          }
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'Take the time from nowProvider (lib/core/clock.dart) instead:\n'
          '${offenders.join('\n')}',
    );
  });
}
