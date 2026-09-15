import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/fonts.dart';

/// Test configuration scoped to `test/goldens/`.
///
/// Golden files would be unreadable boxes without real fonts, so the app's
/// Inter faces and the SDK's MaterialIcons are registered before any golden
/// test runs.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await loadAppFonts();
  await testMain();
}
