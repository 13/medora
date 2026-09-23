import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('presentation layer uses theme tokens, not static colors', () {
    final offenders = <String>[];
    final allowed = RegExp(r'Colors\.(transparent|black)\b');
    // A barcode has to read black-on-white to a scanner whatever the app's
    // theme is (dark mode would print a light barcode on a dark page), so
    // these two intentionally paint fixed colors rather than theme tokens.
    // The attachment viewer is a full-screen photo/PDF chrome, black with
    // white icons like a native gallery, on purpose regardless of the
    // app's light/dark setting.
    const exemptFiles = {
      'lib/presentation/screens/rx/pharmacy_screen.dart',
      'lib/presentation/widgets/code39.dart',
      'lib/presentation/screens/rx/attachment_viewer.dart',
    };
    for (final file in Directory(
      'lib/presentation',
    ).listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      if (exemptFiles.any(file.path.endsWith)) continue;
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
        if (hasStatic || hasColors) {
          offenders.add('${file.path}:${i + 1}: ${line.trim()}');
        }
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });
}
