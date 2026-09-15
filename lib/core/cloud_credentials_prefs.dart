/// Medora - Reading the runtime cloud credentials out of `SharedPreferences`.
///
/// Kept beside [CloudCredentials] rather than on it: `app_config.dart` is
/// imported by every layer (and by tests that never touch a plugin), so it
/// stays free of `shared_preferences`. The keys themselves live on
/// [CloudCredentials], which owns the storage contract.
library;

import 'package:medora/core/app_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The credentials Settings stored on this device, or null when either half
/// is missing - a URL without a key is not usable configuration.
CloudCredentials? readCloudCredentials(SharedPreferences prefs) {
  final url = prefs.getString(CloudCredentials.prefsUrlKey)?.trim() ?? '';
  final key = prefs.getString(CloudCredentials.prefsKeyKey)?.trim() ?? '';
  if (url.isEmpty || key.isEmpty) return null;
  return CloudCredentials(url: url, anonKey: key);
}
