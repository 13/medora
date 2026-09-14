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
  const BiometricGate({super.key, required this.child, this.authenticate});

  final Widget child;

  /// Test seam. When null (production) the gate talks to [SecurityService].
  final Future<AuthOutcome> Function()? authenticate;

  @override
  ConsumerState<BiometricGate> createState() => _BiometricGateState();
}

class _BiometricGateState extends ConsumerState<BiometricGate>
    with WidgetsBindingObserver {
  bool _isAuthenticating = false;

  /// Result of the last attempt; null before the first one.
  AuthOutcome? _outcome;

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

  Future<AuthOutcome> _authenticate() async {
    final injected = widget.authenticate;
    if (injected != null) return injected();
    if (!await SecurityService.instance.canAuthenticate()) {
      return AuthOutcome.notAvailable;
    }
    return SecurityService.instance.authenticate();
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
      final outcome = await _authenticate();
      if (!mounted) return;
      setState(() => _outcome = outcome);
      if (outcome == AuthOutcome.success) lock.setLocked(false);
    } finally {
      _isAuthenticating = false;
    }
  }

  /// Turning the setting off is the only way back in when the lock can never
  /// succeed (no credential enrolled, no hardware, biometrics locked out).
  Future<void> _disableAppLock() async {
    final biometrics = ref.read(biometricsEnabledProvider.notifier);
    final lock = ref.read(isBiometricLockedProvider.notifier);
    await biometrics.set(false);
    lock.setLocked(false);
  }

  String? _message(AppLocalizations l10n) => switch (_outcome) {
    null || AuthOutcome.success || AuthOutcome.cancelled => null,
    AuthOutcome.notEnrolled => l10n.biometricNotEnrolled,
    AuthOutcome.notAvailable => l10n.biometricNotAvailable,
    AuthOutcome.lockedOut ||
    AuthOutcome.permanentlyLockedOut => l10n.biometricLockedOut,
    AuthOutcome.error => l10n.biometricFailed,
  };

  @override
  Widget build(BuildContext context) {
    final locked =
        ref.watch(isBiometricLockedProvider) &&
        ref.watch(biometricsEnabledProvider);
    if (!locked) return widget.child;

    final l10n = AppLocalizations.of(context);
    final message = _message(l10n);
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/icon/medora_icon.png',
                height: 120,
                errorBuilder: (_, _, _) => Icon(
                  Icons.lock_outline,
                  size: 80,
                  color: theme.colorScheme.primary,
                ),
              ),
              if (message != null) ...[
                const SizedBox(height: 24),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: _checkBiometrics,
                icon: const Icon(Icons.fingerprint),
                label: Text(l10n.unlockMedora),
              ),
              if (_outcome?.isUnrecoverable ?? false) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _disableAppLock,
                  child: Text(l10n.disableAppLock),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
