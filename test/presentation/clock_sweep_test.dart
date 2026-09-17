import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _wallClock = RegExp(
  r'\b(DateTime\.now\(|DateTime\.timestamp\(|TimeOfDay\.now\()',
);

/// Every line under [dirs] that reads the wall clock, except the lines
/// that contain one of [allowed].
List<String> _wallClockReads(
  List<String> dirs, {
  List<String> allowed = const [],
}) {
  final offenders = <String>[];
  for (final dir in dirs) {
    for (final file in Directory(
      dir,
    ).listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (!_wallClock.hasMatch(lines[i])) continue;
        if (allowed.any(lines[i].contains)) continue;
        offenders.add('${file.path}:${i + 1}: ${lines[i].trim()}');
      }
    }
  }
  return offenders;
}

/// `lib/core/clock.dart` is the single "now" seam: everything else takes the
/// time from `nowProvider` / an injected clock, so tests can pin it.
void main() {
  test('presentation and domain read the clock through the seam', () {
    final offenders = _wallClockReads(['lib/presentation', 'lib/domain']);
    expect(
      offenders,
      isEmpty,
      reason:
          'Take the time from nowProvider (lib/core/clock.dart) instead:\n'
          '${offenders.join('\n')}',
    );
  });

  test('the repositories stamp their writes with the injected clock', () {
    // The invite code only uses the clock as a source of variety.
    final offenders = _wallClockReads(
      ['lib/data/repositories'],
      allowed: ['microsecondsSinceEpoch'],
    );
    expect(
      offenders,
      isEmpty,
      reason:
          'Take the time from the repository\'s injected clock instead:\n'
          '${offenders.join('\n')}',
    );
  });
}
