/// Medora - The build's configuration as a provider.
///
/// Its own file on purpose: both `settings_providers.dart` and
/// `app_update_provider.dart` need it, and neither should have to import the
/// other to get it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/app_config.dart';

/// Build-time configuration; overridden in tests that need a specific repo.
final appConfigProvider = Provider<AppConfig>(
  (_) => AppConfig.fromEnvironment(),
);
