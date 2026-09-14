/// Medora - App mode (local-only vs cloud sync), persisted.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/presentation/providers/settings_providers.dart';

enum AppMode { localOnly, cloud }

const _kAppMode = 'app_mode';

final appModeProvider = NotifierProvider<AppModeNotifier, AppMode>(AppModeNotifier.new);

class AppModeNotifier extends Notifier<AppMode> {
  @override
  AppMode build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return prefs.getString(_kAppMode) == AppMode.cloud.name ? AppMode.cloud : AppMode.localOnly;
  }

  Future<void> set(AppMode mode) async {
    state = mode;
    await ref.read(sharedPreferencesProvider).setString(_kAppMode, mode.name);
  }
}
