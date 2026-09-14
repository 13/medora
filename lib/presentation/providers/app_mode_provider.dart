/// Medora - App mode (local-only vs cloud sync), persisted.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/presentation/providers/settings_providers.dart';

enum AppMode { localOnly, cloud }

const _kAppMode = 'app_mode';

final appModeProvider = NotifierProvider<AppModeNotifier, AppMode>(
  AppModeNotifier.new,
);

class AppModeNotifier extends Notifier<AppMode> {
  @override
  AppMode build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    final saved = prefs.getString(_kAppMode);
    if (saved != null) {
      return saved == AppMode.cloud.name ? AppMode.cloud : AppMode.localOnly;
    }

    // One-time migration for installs that signed in before `AppMode`
    // existed: there is no persisted `app_mode` pref yet, but the app may
    // already hold a live Supabase session from before this concept was
    // introduced. Treat that as cloud mode (rather than silently dropping
    // the user into local-only) and persist the decision so this branch
    // only ever runs once, on first launch after the upgrade.
    if (SupabaseConfig.isConfigured && SupabaseConfig.isAuthenticated) {
      unawaited(prefs.setString(_kAppMode, AppMode.cloud.name));
      return AppMode.cloud;
    }

    return AppMode.localOnly;
  }

  /// Switching to cloud only flips the mode: nobody is signed in yet, so
  /// marking the local rows for upload here could push one account's data
  /// into the next account that signs in. The auth screen does the marking
  /// once it knows who signed in (see `LocalUploadMarker`).
  Future<void> set(AppMode mode) async {
    state = mode;
    await ref.read(sharedPreferencesProvider).setString(_kAppMode, mode.name);
  }
}
