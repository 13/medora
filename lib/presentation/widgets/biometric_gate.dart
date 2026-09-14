/// Medora - Biometric lock overlay.
///
/// Mounted once (ShellRoute) so exactly one lifecycle observer exists.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/auth_providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/services/security_service.dart';

class BiometricGate extends ConsumerStatefulWidget {
  const BiometricGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<BiometricGate> createState() => _BiometricGateState();
}

class _BiometricGateState extends ConsumerState<BiometricGate>
    with WidgetsBindingObserver {
  bool _isAuthenticating = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkBiometrics());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!ref.read(biometricsEnabledProvider)) return;
    if (state == AppLifecycleState.paused) {
      ref.read(isBiometricLockedProvider.notifier).setLocked(true);
    } else if (state == AppLifecycleState.resumed) {
      _checkBiometrics();
    }
  }

  Future<void> _checkBiometrics() async {
    final lock = ref.read(isBiometricLockedProvider.notifier);
    if (!ref.read(biometricsEnabledProvider)) {
      lock.setLocked(false);
      return;
    }
    if (!ref.read(isBiometricLockedProvider) || _isAuthenticating) return;

    _isAuthenticating = true;
    try {
      if (!await SecurityService.instance.canAuthenticate()) {
        if (mounted) lock.setLocked(false);
        return;
      }
      final ok = await SecurityService.instance.authenticate();
      if (ok && mounted) lock.setLocked(false);
    } finally {
      _isAuthenticating = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final locked =
        ref.watch(isBiometricLockedProvider) &&
        ref.watch(biometricsEnabledProvider);
    if (!locked) return widget.child;

    final l10n = AppLocalizations.of(context);
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/icon/medora_icon.png',
              height: 120,
              errorBuilder: (_, _, _) => Icon(
                Icons.lock_outline,
                size: 80,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: _checkBiometrics,
              icon: const Icon(Icons.fingerprint),
              label: Text(l10n.unlockMedora),
            ),
          ],
        ),
      ),
    );
  }
}
