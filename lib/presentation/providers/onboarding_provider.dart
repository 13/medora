/// Medora - Onboarding Provider
///
/// Persists whether the first-run onboarding sheet has been shown.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/presentation/providers/settings_providers.dart';

const _kOnboardingSeen = 'onboarding_seen';

/// Whether the first-run onboarding has already been shown. False on a
/// fresh install; flipped (and persisted) by [OnboardingSeenNotifier.markSeen]
/// once the sheet is dismissed in any way.
final onboardingSeenProvider = NotifierProvider<OnboardingSeenNotifier, bool>(
  OnboardingSeenNotifier.new,
);

class OnboardingSeenNotifier extends Notifier<bool> {
  @override
  bool build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return prefs.getBool(_kOnboardingSeen) ?? false;
  }

  Future<void> markSeen() async {
    state = true;
    await ref.read(sharedPreferencesProvider).setBool(_kOnboardingSeen, true);
  }
}
