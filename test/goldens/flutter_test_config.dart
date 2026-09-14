import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Test configuration scoped to `test/goldens/`.
///
/// `flutter_test` renders every glyph as a box unless real fonts are
/// registered, so golden files would be unreadable. Load the app's bundled
/// Inter faces plus the MaterialIcons font that ships with the Flutter SDK
/// before running any golden test.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();

  await _loadFont('Inter', const [
    'assets/fonts/Inter-Regular.ttf',
    'assets/fonts/Inter-Medium.ttf',
    'assets/fonts/Inter-SemiBold.ttf',
    'assets/fonts/Inter-Bold.ttf',
  ]);

  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null && flutterRoot.isNotEmpty) {
    await _loadFont('MaterialIcons', [
      '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ]);
  }

  await testMain();
}

/// Registers [paths] under [family]. Missing files are skipped silently so a
/// machine without the SDK font cache still runs the rest of the suite.
Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  var any = false;
  for (final path in paths) {
    final file = File(path);
    if (!file.existsSync()) continue;
    any = true;
    loader.addFont(file.readAsBytes().then(ByteData.sublistView));
  }
  if (any) await loader.load();
}
