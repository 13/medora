import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The data layer (and the domain under it) never depends on the services
/// that orchestrate it: the sync cycle lives in `lib/services` and calls
/// into `lib/data/sync`, never the other way round.
void main() {
  test('lib/data and lib/domain never import lib/services', () {
    // Older imports that predate the rule; no new file may join them.
    const known = {
      'lib/data/models/medication_model.dart':
          'package:medora/services/photo_storage.dart',
      'lib/data/repositories/family_repository_impl.dart':
          'package:medora/services/connectivity_service.dart',
    };
    final import = RegExp(r'''^\s*(import|export)\s+['"]([^'"]+)['"]''');
    final offenders = <String>[];
    for (final dir in ['lib/data', 'lib/domain']) {
      for (final file in Directory(
        dir,
      ).listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        final path = file.path.replaceAll(r'\', '/');
        for (final line in file.readAsLinesSync()) {
          final uri = import.firstMatch(line)?.group(2);
          if (uri == null) continue;
          final intoServices =
              uri.startsWith('package:medora/services/') ||
              uri.contains('/services/');
          if (!intoServices || known[path] == uri) continue;
          offenders.add('$path: $uri');
        }
      }
    }
    expect(offenders, isEmpty);
  });
}
