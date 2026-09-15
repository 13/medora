/// Real fonts for tests that measure text.
///
/// `flutter_test` renders every glyph as a 1-em box unless real fonts are
/// registered, which makes a golden unreadable and a line count meaningless:
/// the app's 12 px label is three times as wide in the test font as it is on
/// a device. Tests that care about either load the app's Inter faces first.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Registers the bundled Inter faces and, when the SDK cache has it, the
/// MaterialIcons font. Safe to call more than once.
Future<void> loadAppFonts() async {
  await _loadFont('Inter', const [
    'assets/fonts/Inter-Regular.ttf',
    'assets/fonts/Inter-Medium.ttf',
    'assets/fonts/Inter-SemiBold.ttf',
    'assets/fonts/Inter-Bold.ttf',
  ]);

  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot == null || flutterRoot.isEmpty) return;
  final materialIconsPath =
      '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
  if (!File(materialIconsPath).existsSync()) {
    debugPrint(
      'fonts: MaterialIcons font not found at $materialIconsPath — '
      'icon glyphs will render as boxes.',
    );
  }
  await _loadFont('MaterialIcons', [materialIconsPath]);
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
