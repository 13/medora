/// Medora - Auth screen.
///
/// Primary path: use the app locally with no account.
/// Secondary path: sign in / sign up for cloud sync (only when the build is configured).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/app_mode_provider.dart';
import 'package:medora/presentation/providers/auth_providers.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/sync_providers.dart';
import 'package:medora/presentation/screens/auth/auth_error_text.dart';

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

  /// The address a sign-up is waiting on confirmation for, or null when no
  /// sign-up is waiting. Set only when Supabase gave back no session, which
  /// is what e-mail confirmation looks like from here.
  String? _awaitingConfirmation;

  /// When the confirmation mail may be asked for again. Supabase rate-limits
  /// resends per address and answers a too-early one with an error, so the
  /// screen refuses first rather than spending the attempt.
  DateTime? _resendAllowedAt;

  /// How long a person waits between resends.
  static const _resendCooldown = Duration(seconds: 60);

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
      final outcome = await auth.signUpWithEmail(email, password);
      if (!mounted) return;
      if (outcome == SignUpOutcome.confirmationRequired) {
        // The account exists and there is no session: say so, instead of
        // leaving the form sitting there as though nothing had happened.
        setState(() {
          _awaitingConfirmation = email;
          // The sign-up itself sent one: Supabase refuses another this soon,
          // so the cooldown starts here rather than at the first press.
          _resendAllowedAt = ref.read(nowProvider)().add(_resendCooldown);
        });
        return;
      }
    } else {
      await auth.signInWithEmail(email, password);
    }
    if (!mounted) return;
    if (ref.read(authControllerProvider) is AsyncError) return;
    await _claimLocalDataForSignedInUser();
  }

  /// Asks for the confirmation mail again, unless the cooldown says not to.
  Future<void> _resend() async {
    final email = _awaitingConfirmation;
    if (email == null) return;
    final l10n = AppLocalizations.of(context);
    final now = ref.read(nowProvider)();
    final until = _resendAllowedAt;
    if (until != null && now.isBefore(until)) {
      // Refused here, not at the server: Supabase counts a too-early resend
      // against the address either way, so spending it buys nothing.
      final left = until.difference(now).inSeconds + 1;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.resendCooldown(left))));
      return;
    }
    await ref.read(authControllerProvider.notifier).resendConfirmation(email);
    if (!mounted) return;
    if (ref.read(authControllerProvider) is AsyncError) return;
    setState(
      () => _resendAllowedAt = ref.read(nowProvider)().add(_resendCooldown),
    );
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.confirmationResent)));
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
    final userId = ref.read(currentUserProvider)?.id;
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
          SnackBar(content: Text(authErrorMessage(next.error, l10n))),
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
                      filterQuality: FilterQuality.high,
                      errorBuilder: (_, _, _) => Icon(
                        Icons.medication,
                        size: 80,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    l10n.appTitle,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),

                  // ── Primary: local-only ──
                  FilledButton.icon(
                    onPressed: () => ref
                        .read(appModeProvider.notifier)
                        .set(AppMode.localOnly),
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
                        // The label is a sentence, so it gets the lion's
                        // share: an even three-way split wrapped the English
                        // one at 412 px. Flexible, not Expanded, so it still
                        // gives way at a large text scale instead of
                        // overflowing.
                        const Expanded(child: Divider()),
                        Flexible(
                          flex: 6,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Text(
                              l10n.orSignInForCloud,
                              style: theme.textTheme.bodySmall,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                        const Expanded(child: Divider()),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (_awaitingConfirmation != null)
                      _ConfirmationPanel(
                        email: _awaitingConfirmation!,
                        busy: authState.isLoading,
                        onResend: _resend,
                        onBack: () => setState(() {
                          _awaitingConfirmation = null;
                          _isSignUp = false;
                        }),
                      )
                    else
                      Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            TextFormField(
                              controller: _emailController,
                              decoration: InputDecoration(
                                labelText: l10n.email,
                                prefixIcon: const Icon(Icons.email),
                              ),
                              keyboardType: TextInputType.emailAddress,
                              autofillHints: const [AutofillHints.email],
                              validator: (v) => (v == null || !v.contains('@'))
                                  ? l10n.invalidEmail
                                  : null,
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: _passwordController,
                              decoration: InputDecoration(
                                labelText: l10n.password,
                                prefixIcon: const Icon(Icons.lock),
                                suffixIcon: IconButton(
                                  icon: Icon(
                                    _obscurePassword
                                        ? Icons.visibility
                                        : Icons.visibility_off,
                                  ),
                                  onPressed: () => setState(
                                    () => _obscurePassword = !_obscurePassword,
                                  ),
                                ),
                              ),
                              obscureText: _obscurePassword,
                              autofillHints: const [AutofillHints.password],
                              validator: (v) => (v == null || v.length < 6)
                                  ? l10n.passwordTooShort
                                  : null,
                            ),
                            const SizedBox(height: 16),
                            OutlinedButton(
                              onPressed: authState.isLoading ? null : _submit,
                              child: authState.isLoading
                                  ? const SizedBox(
                                      height: 20,
                                      width: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Text(_isSignUp ? l10n.signUp : l10n.signIn),
                            ),
                            TextButton(
                              onPressed: () =>
                                  setState(() => _isSignUp = !_isSignUp),
                              child: Text(
                                _isSignUp
                                    ? l10n.alreadyHaveAccount
                                    : l10n.dontHaveAccount,
                              ),
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

/// What a sign-up that is waiting on its confirmation mail shows instead of
/// the form: which address it went to, and a way to send it again.
///
/// The form is replaced rather than joined, because every field in it now
/// belongs to an account that already exists — typing a different password
/// there would do nothing.
class _ConfirmationPanel extends StatelessWidget {
  const _ConfirmationPanel({
    required this.email,
    required this.busy,
    required this.onResend,
    required this.onBack,
  });

  final String email;
  final bool busy;
  final Future<void> Function() onResend;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(
              Icons.mark_email_unread_outlined,
              size: 32,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 12),
            Text(
              l10n.checkYourEmailTitle,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.checkYourEmailBody(email),
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: busy ? null : () => unawaited(onResend()),
              child: Text(l10n.resendConfirmation),
            ),
            TextButton(onPressed: onBack, child: Text(l10n.backToSignIn)),
          ],
        ),
      ),
    );
  }
}
