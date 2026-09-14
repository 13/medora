/// Medora - Auth screen.
///
/// Primary path: use the app locally with no account.
/// Secondary path: sign in / sign up for cloud sync (only when the build is configured).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/app_mode_provider.dart';
import 'package:medora/presentation/providers/auth_providers.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/sync_providers.dart';

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isSignUp = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final auth = ref.read(authControllerProvider.notifier);
    if (_isSignUp) {
      await auth.signUpWithEmail(email, password);
    } else {
      await auth.signInWithEmail(email, password);
    }
    if (!mounted) return;
    if (ref.read(authControllerProvider) is AsyncError) return;
    await _claimLocalDataForSignedInUser();
  }

  /// Decides what happens to the rows already on this device now that we know
  /// who signed in.
  ///
  /// The common case — data created before any account, or the same account
  /// signing back in — is marked for upload silently. Data that belongs to a
  /// *different* account is never uploaded without asking: merging it into
  /// the new account would leak one person's medication history into
  /// another's.
  Future<void> _claimLocalDataForSignedInUser() async {
    final l10n = AppLocalizations.of(context);
    final userId = SupabaseConfig.clientOrNull?.auth.currentUser?.id;
    // Sign-up with e-mail confirmation on returns no session yet; there is
    // nothing to claim until the user actually signs in.
    if (userId == null) return;
    final marker = ref.read(localUploadMarkerProvider);
    try {
      if (!await marker.hasDataFromAnotherAccount(userId)) {
        await marker.markAllForUpload(userId);
        await marker.setOwner(userId);
        return;
      }
      if (!mounted) return;
      final merge = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.foreignDataTitle),
          content: Text(l10n.foreignDataBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.foreignDataDelete),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.foreignDataMerge),
            ),
          ],
        ),
      );
      if (merge == null) return;
      if (merge) {
        await marker.markAllForUpload(userId);
      } else {
        await ref.read(localDataWiperProvider).wipe();
      }
      await marker.setOwner(userId);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.errorWithDetails(e.toString()))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final authState = ref.watch(authControllerProvider);
    final cloudAvailable = SupabaseConfig.isConfigured;

    ref.listen(authControllerProvider, (previous, next) {
      if (next is AsyncError) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(next.error.toString())),
        );
      }
    });

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Image.asset(
                      'assets/icon/medora_icon_pill.png',
                      height: 160,
                      errorBuilder: (_, _, _) => Icon(Icons.medication, size: 80, color: theme.colorScheme.primary),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    l10n.appTitle,
                    style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),

                  // ── Primary: local-only ──
                  FilledButton.icon(
                    onPressed: () => ref.read(appModeProvider.notifier).set(AppMode.localOnly),
                    icon: const Icon(Icons.phone_android),
                    label: Text(l10n.useOnThisDevice),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.useOnThisDeviceDesc,
                    style: theme.textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),

                  // ── Secondary: cloud ──
                  if (cloudAvailable) ...[
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        const Expanded(child: Divider()),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(l10n.orSignInForCloud, style: theme.textTheme.bodySmall),
                        ),
                        const Expanded(child: Divider()),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextFormField(
                            controller: _emailController,
                            decoration: InputDecoration(labelText: l10n.email, prefixIcon: const Icon(Icons.email)),
                            keyboardType: TextInputType.emailAddress,
                            autofillHints: const [AutofillHints.email],
                            validator: (v) => (v == null || !v.contains('@')) ? l10n.invalidEmail : null,
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _passwordController,
                            decoration: InputDecoration(
                              labelText: l10n.password,
                              prefixIcon: const Icon(Icons.lock),
                              suffixIcon: IconButton(
                                icon: Icon(_obscurePassword ? Icons.visibility : Icons.visibility_off),
                                onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                              ),
                            ),
                            obscureText: _obscurePassword,
                            autofillHints: const [AutofillHints.password],
                            validator: (v) => (v == null || v.length < 6) ? l10n.passwordTooShort : null,
                          ),
                          const SizedBox(height: 16),
                          OutlinedButton(
                            onPressed: authState.isLoading ? null : _submit,
                            child: authState.isLoading
                                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                                : Text(_isSignUp ? l10n.signUp : l10n.signIn),
                          ),
                          TextButton(
                            onPressed: () => setState(() => _isSignUp = !_isSignUp),
                            child: Text(_isSignUp ? l10n.alreadyHaveAccount : l10n.dontHaveAccount),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
